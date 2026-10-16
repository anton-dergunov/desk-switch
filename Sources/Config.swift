import Foundation

struct Config: Codable {
    struct Host: Codable {
        /// Key used in the `inputs` and `channels` maps below.
        var name: String
        /// Global hotkey meaning "switch to this host", e.g. "F19" or "ctrl+opt+cmd+2".
        var hotkey: String?
    }

    struct Display: Codable {
        /// Substring of the EDID product name; omit to match every external display.
        var name: String?
        /// DDC input-source value (VCP 0x60) per host.
        var inputs: [String: Int]
    }

    struct LogitechDevice: Codable {
        var name: String
        /// USB/Bluetooth product ID, e.g. "0xB042" (shown by `desk-switch status`).
        var productId: String
        /// Easy-Switch channel per host, 1-based as printed on the device.
        var channels: [String: Int]

        var productID: Int? { Int(productId.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16) }
    }

    var hosts: [Host]
    var displays: [Display]
    var logitech: [LogitechDevice]

    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/desk-switch")
    static let url = directory.appendingPathComponent("config.json")

    static let `default` = Config(
        hosts: [Host(name: "personal", hotkey: "F18"), Host(name: "work", hotkey: "F19")],
        displays: [Display(name: "PHL 49B2U5900", inputs: ["personal": 21, "work": 15])],
        logitech: [LogitechDevice(name: "MX Master 4", productId: "0xB042", channels: ["personal": 2, "work": 3])])

    /// Loads the config, writing the default one on first run.
    static func load() throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(Config.default).write(to: url)
            return .default
        }
        do {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        } catch {
            throw ConfigError(description: "\(url.path): \(error)")
        }
    }

    func host(named name: String) -> Host? {
        hosts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

struct ConfigError: Error, CustomStringConvertible {
    let description: String
}
