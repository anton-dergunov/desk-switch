import Foundation
import IOKit.hid

// Logitech HID++ 2.0 over the device's vendor collection (usage page 0xFF43,
// usage 0x0202, 20-byte "long" reports). Used here only for the CHANGE_HOST
// feature, which moves an Easy-Switch device to another channel.

struct HIDPPError: Error, CustomStringConvertible {
    let description: String
}

final class HIDPPDevice {
    static let logitechVendorID = 0x046D

    let device: IOHIDDevice
    let product: String
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var expect: (feature: UInt8, function: UInt8)?
    private var reply: Result<[UInt8], HIDPPError>?
    /// 0xFF addresses a device connected directly (Bluetooth or USB cable)
    /// rather than through a Unifying or Bolt receiver.
    private var deviceIndex: UInt8 = 0xFF
    private static let softwareID: UInt8 = 0x0A
    private static let longReport: UInt8 = 0x11

    private init(device: IOHIDDevice) {
        self.device = device
        product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Logitech device"
    }

    deinit {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        inputBuffer.deallocate()
    }

    /// Opens every connected device with this product ID that exposes the HID++ long-report collection.
    /// The device is opened non-exclusively, so it keeps working as a mouse and needs no root.
    static func open(productID: Int) throws -> [HIDPPDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: logitechVendorID,
            kIOHIDProductIDKey: productID,
            kIOHIDDeviceUsagePageKey: 0xFF43,
            kIOHIDDeviceUsageKey: 0x0202,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return try set.map { raw in
            let device = HIDPPDevice(device: raw)
            let opened = IOHIDDeviceOpen(raw, IOOptionBits(kIOHIDOptionsTypeNone))
            guard opened == kIOReturnSuccess else {
                let hint = opened == kIOReturnNotPermitted ? " (allow Input Monitoring for this app in System Settings)" : ""
                throw HIDPPError(description: "\(device.product): cannot open (\(String(format: "0x%08x", opened)))\(hint)")
            }
            device.listen()
            return device
        }
    }

    private func listen() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, { context, _, _, _, _, report, length in
            guard let context else { return }
            let me = Unmanaged<HIDPPDevice>.fromOpaque(context).takeUnretainedValue()
            me.received(Array(UnsafeBufferPointer(start: report, count: length)))
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func received(_ report: [UInt8]) {
        guard let expect, report.count >= 6, report[0] == Self.longReport || report[0] == 0x10 else { return }
        let tag = expect.function << 4 | Self.softwareID
        if report[2] == expect.feature, report[3] == tag {
            reply = .success(Array(report[4...]))
        } else if report[2] == 0xFF, report[3] == expect.feature, report[4] == tag {
            reply = .failure(HIDPPError(description: "\(product): HID++ error \(report[5])"))
        }
    }

    /// Sends one request and, unless `wait` is 0, waits for the matching reply.
    @discardableResult
    func call(feature: UInt8, function: UInt8, params: [UInt8] = [], wait: TimeInterval = 1.0) throws -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 20)
        report[0] = Self.longReport
        report[1] = deviceIndex
        report[2] = feature
        report[3] = function << 4 | Self.softwareID
        report.replaceSubrange(4..<(4 + params.count), with: params)

        expect = (feature, function)
        reply = nil
        defer { expect = nil }
        let sent = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(Self.longReport), report, report.count)
        guard sent == kIOReturnSuccess else {
            throw HIDPPError(description: "\(product): send failed (\(String(format: "0x%08x", sent)))")
        }
        guard wait > 0 else { return [] }
        let deadline = Date().addingTimeInterval(wait)
        while reply == nil, Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
        }
        guard let reply else { throw HIDPPError(description: "\(product): no reply") }
        return try reply.get()
    }

    /// IRoot.getFeature: the index of a feature on this device, or nil if it lacks it.
    func featureIndex(_ featureID: UInt16) throws -> UInt8? {
        let reply = try call(feature: 0x00, function: 0, params: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)])
        return reply[0] == 0 ? nil : reply[0]
    }

    // MARK: CHANGE_HOST (0x1814)

    private var changeHostIndex: UInt8?

    private func changeHost() throws -> UInt8 {
        if let changeHostIndex { return changeHostIndex }
        guard let index = try featureIndex(0x1814) else {
            throw HIDPPError(description: "\(product): no CHANGE_HOST feature")
        }
        changeHostIndex = index
        return index
    }

    /// Number of Easy-Switch channels and the current one, both 1-based as printed on the device.
    func hostInfo() throws -> (count: Int, current: Int) {
        let reply = try call(feature: try changeHost(), function: 0)
        return (Int(reply[0]), Int(reply[1]) + 1)
    }

    /// Moves the device to a 1-based channel. The device drops the connection right
    /// away, so no reply is awaited.
    func setHost(_ channel: Int) throws {
        try call(feature: try changeHost(), function: 1, params: [UInt8(channel - 1)], wait: 0)
    }
}
