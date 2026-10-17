import AppKit
import Carbon.HIToolbox
import IOKit.hid

/// Menu-bar agent: one menu item and one global hotkey per host.
final class Agent: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var grantItem: NSMenuItem?
    private var config = Config.default
    private var hotkeys: [EventHotKeyRef] = []
    private let queue = DispatchQueue(label: "desk-switch.switch")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.2.swap", accessibilityDescription: "desk-switch")
        installHotkeyHandler()
        // Opening the mouse's HID++ channel needs Input Monitoring; this shows the
        // system prompt once (and again after a rebuild, see build.sh).
        if !hasInputMonitoring {
            log("requesting Input Monitoring (needed to switch Logitech devices)")
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        reload()
    }

    private var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    func menuWillOpen(_ menu: NSMenu) {
        // The grant can change while the agent runs.
        grantItem?.isHidden = hasInputMonitoring
    }

    @objc private func reload() {
        do {
            config = try Config.load()
            log("config loaded: \(config.hosts.map(\.name).joined(separator: ", "))")
        } catch {
            log("config error: \(error)")
        }
        registerHotkeys()
        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()
        for (index, host) in config.hosts.enumerated() {
            let title = "Switch to \(host.name.capitalized)" + (host.hotkey.map { "  (\($0))" } ?? "")
            let item = NSMenuItem(title: title, action: #selector(menuSwitch(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let grant = NSMenuItem(title: "Grant Input Monitoring…", action: #selector(openPrivacySettings),
                               keyEquivalent: "")
        grant.target = self
        grant.isHidden = hasInputMonitoring
        grantItem = grant
        menu.addItem(grant)
        let edit = NSMenuItem(title: "Edit Config…", action: #selector(editConfig), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        let reloadItem = NSMenuItem(title: "Reload Config", action: #selector(reload), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func openPrivacySettings() {
        // macOS does not always list an ad-hoc signed agent by itself, so also show the
        // app in Finder: it can be dragged into the list, or picked with its "+" button.
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func menuSwitch(_ sender: NSMenuItem) {
        perform(hostIndex: sender.tag)
    }

    @objc private func editConfig() {
        NSWorkspace.shared.open(Config.url)
    }

    fileprivate func perform(hostIndex: Int) {
        guard config.hosts.indices.contains(hostIndex) else { return }
        let host = config.hosts[hostIndex]
        let config = config
        // HID++ replies arrive on the calling thread's run loop, so switches run on
        // their own serial queue instead of blocking the menu.
        queue.async { switchTo(host, config: config) }
    }

    // MARK: Hotkeys (Carbon RegisterEventHotKey: needs no Accessibility permission)

    private static let signature = OSType(0x6453_5754) // 'dSWT'

    private func installHotkeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let agent = Unmanaged<Agent>.fromOpaque(context).takeUnretainedValue()
            log("hotkey \(agent.config.hosts.indices.contains(Int(id.id)) ? agent.config.hosts[Int(id.id)].name : "?")")
            agent.perform(hostIndex: Int(id.id))
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func registerHotkeys() {
        hotkeys.forEach { UnregisterEventHotKey($0) }
        hotkeys = []
        for (index, host) in config.hosts.enumerated() {
            guard let spec = host.hotkey else { continue }
            guard let (code, modifiers) = Hotkey.parse(spec) else {
                log("unknown hotkey \"\(spec)\" for \(host.name)")
                continue
            }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: Self.signature, id: UInt32(index)),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotkeys.append(ref)
            } else {
                log("cannot register hotkey \(spec) for \(host.name) (status \(status)); is another app using it?")
            }
        }
    }
}

enum Hotkey {
    private static let keys: [String: Int] = {
        var keys = [
            "F1": kVK_F1, "F2": kVK_F2, "F3": kVK_F3, "F4": kVK_F4, "F5": kVK_F5, "F6": kVK_F6, "F7": kVK_F7,
            "F8": kVK_F8, "F9": kVK_F9, "F10": kVK_F10, "F11": kVK_F11, "F12": kVK_F12, "F13": kVK_F13,
            "F14": kVK_F14, "F15": kVK_F15, "F16": kVK_F16, "F17": kVK_F17, "F18": kVK_F18, "F19": kVK_F19,
            "F20": kVK_F20,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ]
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
                       kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
                       kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
                       kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
        for (offset, code) in letters.enumerated() {
            keys[String(UnicodeScalar(UInt8(65 + offset)))] = code
        }
        return keys
    }()

    private static let modifiers: [String: Int] = [
        "cmd": cmdKey, "command": cmdKey, "ctrl": controlKey, "control": controlKey,
        "opt": optionKey, "option": optionKey, "alt": optionKey, "shift": shiftKey,
    ]

    /// Parses "F19" or "ctrl+opt+cmd+K" into a Carbon key code and modifier mask.
    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        let parts = spec.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, let code = keys[key.uppercased()] else { return nil }
        var mask = 0
        for part in parts.dropLast() {
            guard let bit = modifiers[part.lowercased()] else { return nil }
            mask |= bit
        }
        return (UInt32(code), UInt32(mask))
    }
}
