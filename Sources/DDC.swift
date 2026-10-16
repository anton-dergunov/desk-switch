import Foundation
import IOKit

// DDC/CI over the Apple Silicon display pipeline. IOAVService is private API in
// IOKit (the same calls m1ddc, MonitorControl and BetterDisplay use).

typealias IOAVService = CFTypeRef

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<IOAVService>?

@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: IOAVService, _ chipAddress: UInt32, _ offset: UInt32,
                                _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: IOAVService, _ chipAddress: UInt32, _ dataAddress: UInt32,
                                 _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

enum VCP {
    static let inputSource: UInt8 = 0x60
}

struct DDCError: Error, CustomStringConvertible {
    let description: String
}

struct ExternalDisplay {
    let name: String
    let service: IOAVService

    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51
    private static let settle: useconds_t = 10_000

    /// External displays in IORegistry order. Each external `DCPAVServiceProxy` is
    /// paired with the `AppleCLCD2` framebuffer that precedes it, which carries
    /// the EDID product name.
    static func all() -> [ExternalDisplay] {
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [ExternalDisplay] = []
        var lastName: String?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let name = registryName(entry)
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                lastName = productName(entry) ?? lastName
            } else if name == "DCPAVServiceProxy", stringProperty(entry, "Location") == "External",
                      let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                result.append(ExternalDisplay(name: lastName ?? "Unknown display", service: service))
                lastName = nil
            }
        }
        return result
    }

    /// Reads a VCP feature, returning (current, maximum).
    func read(_ vcp: UInt8) throws -> (current: Int, maximum: Int) {
        var lastError = "no reply"
        for _ in 0..<3 {
            var request: [UInt8] = [0x82, 0x01, vcp, 0]
            request[3] = request[0..<3].reduce(0x6E, ^)
            usleep(Self.settle)
            let written = IOAVServiceWriteI2C(service, Self.chipAddress, Self.dataAddress, &request, UInt32(request.count))
            guard written == kIOReturnSuccess else {
                lastError = "write failed (\(String(format: "0x%08x", written)))"
                continue
            }
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 12)
            let read = IOAVServiceReadI2C(service, Self.chipAddress, Self.dataAddress, &reply, UInt32(reply.count))
            guard read == kIOReturnSuccess else {
                lastError = "read failed (\(String(format: "0x%08x", read)))"
                continue
            }
            // 6E len 02 result vcp type maxH maxL curH curL chk
            guard reply[2] == 0x02, reply[4] == vcp else {
                lastError = "unexpected reply \(hex(reply))"
                continue
            }
            guard reply[3] == 0 else { throw DDCError(description: "display does not support VCP \(hex([vcp]))") }
            return (Int(reply[8]) << 8 | Int(reply[9]), Int(reply[6]) << 8 | Int(reply[7]))
        }
        throw DDCError(description: "\(name): \(lastError)")
    }

    func write(_ vcp: UInt8, _ value: Int) throws {
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF), 0]
        packet[5] = packet[0..<5].reduce(0x6E ^ 0x51, ^)
        // Displays drop DDC writes now and then; sending twice is what m1ddc does too.
        var result = kIOReturnSuccess
        for _ in 0..<2 {
            usleep(Self.settle)
            result = IOAVServiceWriteI2C(service, Self.chipAddress, Self.dataAddress, &packet, UInt32(packet.count))
        }
        guard result == kIOReturnSuccess else {
            throw DDCError(description: "\(name): write failed (\(String(format: "0x%08x", result)))")
        }
    }
}

private func registryName(_ entry: io_registry_entry_t) -> String {
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
    defer { buffer.deallocate() }
    guard IORegistryEntryGetName(entry, buffer) == KERN_SUCCESS else { return "" }
    return String(cString: buffer)
}

private func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
}

private func productName(_ entry: io_registry_entry_t) -> String? {
    guard let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
          let product = attributes["ProductAttributes"] as? [String: Any] else { return nil }
    return product["ProductName"] as? String
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}
