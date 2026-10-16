import Foundation

private let timestamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

func log(_ message: String) {
    print("\(timestamp.string(from: Date())) \(message)")
}

func displays(matching name: String?) -> [ExternalDisplay] {
    let all = ExternalDisplay.all()
    guard let name else { return all }
    return all.filter { $0.name.localizedCaseInsensitiveContains(name) }
}

/// Moves every configured device to `host`. Peripherals go first, since the monitor
/// switch is the slow part and the mouse should already be on its way. Each device
/// is attempted even if another fails. Returns the problems, empty on success.
@discardableResult
func switchTo(_ host: Config.Host, config: Config) -> [String] {
    log("switch to \(host.name)")
    var problems: [String] = []

    for entry in config.logitech {
        guard let channel = entry.channels[host.name] else { continue }
        guard let productID = entry.productID else {
            problems.append("\(entry.name): bad productId \(entry.productId)")
            continue
        }
        do {
            let devices = try HIDPPDevice.open(productID: productID)
            if devices.isEmpty { problems.append("\(entry.name): not connected to this Mac") }
            for device in devices {
                let info = try device.hostInfo()
                if info.current == channel {
                    log("  \(entry.name): already on channel \(channel)")
                } else {
                    try device.setHost(channel)
                    log("  \(entry.name): channel \(info.current) -> \(channel)")
                }
            }
        } catch {
            problems.append("\(error)")
        }
    }

    for entry in config.displays {
        guard let input = entry.inputs[host.name] else { continue }
        let found = displays(matching: entry.name)
        if found.isEmpty { problems.append("\(entry.name ?? "display"): not found") }
        for display in found {
            do {
                try display.write(VCP.inputSource, input)
                log("  \(display.name): input -> \(input)")
            } catch {
                problems.append("\(error)")
            }
        }
    }

    for problem in problems { log("  problem: \(problem)") }
    return problems
}
