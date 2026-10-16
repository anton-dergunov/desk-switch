import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
    usage: desk-switch                       run the menu-bar agent (what the LaunchAgent starts)
           desk-switch status                show displays and Logitech devices as seen from this Mac
           desk-switch to <host>             switch everything to <host>
           desk-switch ddc get <vcp>         read a VCP code (e.g. 0x60 = input) from the configured displays
           desk-switch ddc set <vcp> <val>   write a VCP code to the configured displays

    config: \(Config.url.path)
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func loadConfig() -> Config {
    do { return try Config.load() } catch { fail("config error: \(error)") }
}

func parseNumber(_ text: String) -> Int? {
    text.lowercased().hasPrefix("0x") ? Int(text.dropFirst(2), radix: 16) : Int(text)
}

func status(_ config: Config) {
    print("Displays:")
    let all = ExternalDisplay.all()
    if all.isEmpty { print("  (no external display found)") }
    for display in all {
        let input: String
        do {
            let value = try display.read(VCP.inputSource)
            let owner = config.displays.first { $0.name.map(display.name.localizedCaseInsensitiveContains) ?? true }?
                .inputs.first { $0.value == value.current }?.key
            input = "\(value.current)" + (owner.map { " (\($0))" } ?? "")
        } catch {
            input = "unreadable: \(error)"
        }
        print("  \(display.name): input \(input)")
    }

    print("Logitech devices:")
    for entry in config.logitech {
        guard let productID = entry.productID else {
            print("  \(entry.name): bad productId \(entry.productId)")
            continue
        }
        do {
            let devices = try HIDPPDevice.open(productID: productID)
            if devices.isEmpty { print("  \(entry.name): not connected to this Mac") }
            for device in devices {
                let info = try device.hostInfo()
                let owner = entry.channels.first { $0.value == info.current }?.key
                print("  \(device.product): channel \(info.current) of \(info.count)" + (owner.map { " (\($0))" } ?? ""))
            }
        } catch {
            print("  \(entry.name): \(error)")
        }
    }

    print("Hotkeys:")
    for host in config.hosts {
        print("  \(host.hotkey ?? "(none)") -> \(host.name)")
    }
}

func ddc(_ args: [String], _ config: Config) {
    guard args.count >= 2, let vcp = parseNumber(args[1]).map(UInt8.init) else { fail(usage) }
    let names = config.displays.map(\.name)
    let targets = names.contains(nil) || names.isEmpty
        ? ExternalDisplay.all()
        : names.compactMap { $0 }.flatMap { displays(matching: $0) }
    if targets.isEmpty { fail("no matching external display") }
    for display in targets {
        do {
            switch args[0] {
            case "get":
                let value = try display.read(vcp)
                print("\(display.name): \(value.current) (max \(value.maximum))")
            case "set":
                guard args.count == 3, let value = parseNumber(args[2]) else { fail(usage) }
                try display.write(vcp, value)
                print("\(display.name): set \(value)")
            default:
                fail(usage)
            }
        } catch {
            fail("\(error)")
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case nil:
    let app = NSApplication.shared
    let agent = Agent()
    app.delegate = agent
    app.setActivationPolicy(.accessory)
    app.run()
case "status":
    status(loadConfig())
case "to":
    let config = loadConfig()
    guard arguments.count == 2 else { fail(usage) }
    guard let host = config.host(named: arguments[1]) else {
        fail("unknown host \(arguments[1]); configured: \(config.hosts.map(\.name).joined(separator: ", "))")
    }
    exit(switchTo(host, config: config).isEmpty ? 0 : 1)
case "ddc":
    ddc(Array(arguments.dropFirst()), loadConfig())
case "-h", "--help", "help":
    print(usage)
default:
    fail(usage)
}
