import AppKit
import Foundation

final class SidewinderApp: NSObject, NSApplicationDelegate, NSMenuDelegate, SidewinderDelegate {
    private var config: Config
    private let configURL: URL
    private let device = SidewinderDevice()
    private let injector = Injector()
    private var statusItem: NSStatusItem?
    private var lastMask: UInt32 = 0
    private var lastProfileCycle: TimeInterval = 0
    private let listenOnly: Bool

    init(configURL: URL, debug: Bool, listenOnly: Bool) {
        self.configURL = configURL
        self.config = Config.loadOrCreate(url: configURL)
        self.listenOnly = listenOnly
        super.init()
        device.debug = debug
        device.delegate = self
        device.onLog = { [weak self] message in
            self?.log(message)
        }
        injector.onAction = { [weak self] action in
            self?.handleAction(action)
        }
        injector.onCruiseChange = { [weak self] in
            self?.refreshMenu()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !listenOnly {
            setupStatusItem()
        }
        device.start()
        applyHardwareState()
        log("started  profile=\(config.profile) macropad=\(config.currentProfile.macropad) connected=\(device.isConnected) accessibility=\(injector.trusted)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        injector.releaseAll()
        device.stop()
        try? config.save(to: configURL)
    }

    func sidewinderConnected() {
        applyHardwareState()
        refreshMenu()
        log("keyboard connected")
    }

    func sidewinderDisconnected() {
        injector.releaseAll()
        lastMask = 0
        refreshMenu()
        log("keyboard disconnected")
    }

    func sidewinderMacroChanged(mask: UInt32) {
        let changed = mask ^ lastMask
        guard changed != 0 else { return }
        let profile = config.currentProfile
        for bit in 0..<30 {
            let bitMask = UInt32(1) << bit
            guard changed & bitMask != 0 else { continue }
            let name = "S\(bit + 1)"
            let pressed = mask & bitMask != 0
            if listenOnly {
                log("\(name) \(pressed ? "down" : "up")")
                continue
            }
            guard let binding = profile.keys[name] else { continue }
            if pressed {
                injector.press(id: name, binding: binding)
            } else {
                injector.release(id: name, binding: binding)
            }
        }
        lastMask = mask
    }

    func sidewinderSpecial(_ special: SidewinderSpecial, pressed: Bool) {
        log("\(special.rawValue) \(pressed ? "down" : "up")")
        if listenOnly { return }
        if special == .cruise {
            if pressed { injector.cruisePressed() }
            else { injector.cruiseReleased() }
            return
        }
        let name = special.rawValue
        guard let binding = config.currentProfile.keys[name] else {
            if special == .bank, !pressed { cycleProfile() }
            return
        }
        if pressed {
            injector.press(id: name, binding: binding)
        } else {
            injector.release(id: name, binding: binding)
        }
    }

    private func handleAction(_ action: String) {
        switch action.lowercased() {
        case "next-profile":
            cycleProfile()
        case "prev-profile":
            config.setProfile(config.profile - 1)
            persistAndApply()
        case "toggle-macropad":
            config.toggleMacropad()
            persistAndApply()
        case "cruise":
            injector.cruisePressed()
        case "none", "":
            break
        default:
            log("unknown action \(action)")
        }
    }

    private func cycleProfile() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProfileCycle < 0.3 {
            log("ignored extra profile cycle")
            return
        }
        lastProfileCycle = now
        injector.releaseAll()
        lastMask = 0
        config.cycleProfile()
        persistAndApply()
        log("profile \(config.profile) (\(config.currentProfile.name)) macropad=\(config.currentProfile.macropad)")
    }

    private func persistAndApply() {
        applyHardwareState()
        try? config.save(to: configURL)
        refreshMenu()
    }

    private func applyHardwareState() {
        device.apply(profileIndex: config.currentProfileIndex, macropad: config.currentProfile.macropad)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "Sidewinder X6"
        if let image = statusIcon() {
            item.button?.image = image
            item.button?.imagePosition = .imageLeading
        }
        statusItem = item
        refreshMenu()
    }

    private func statusIcon() -> NSImage? {
        let bundle = Bundle.main
        let image = bundle.image(forResource: "StatusIcon")
            ?? bundle.url(forResource: "StatusIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let trusted = injector.trusted
        for item in menu.items where item.title.hasPrefix("Accessibility:") {
            item.title = trusted ? "Accessibility: allowed" : "Accessibility: click to grant"
            item.action = trusted ? nil : #selector(grantAccess)
            item.target = trusted ? nil : self
            item.isEnabled = !trusted
        }
    }

    private func refreshMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.delegate = self
        let connected = device.isConnected ? "Connected" : "Disconnected"
        let trusted = injector.trusted
        menu.addItem(menuItem("Sidewinder X6 — \(connected)", enabled: false))
        menu.addItem(menuItem(
            trusted ? "Accessibility: allowed" : "Accessibility: click to grant",
            action: trusted ? nil : #selector(grantAccess)
        ))
        menu.addItem(.separator())
        for index in 1...Config.defaultProfileCount {
            let profile = index <= config.profiles.count ? config.profiles[index - 1] : nil
            let label = profile.map { "Profile \(index): \($0.name)" } ?? "Profile \(index)"
            let item = menuItem(label, action: #selector(selectProfile(_:)))
            item.tag = index
            item.state = index == config.profile ? .on : .off
            menu.addItem(item)
        }
        let pad = menuItem(
            config.currentProfile.macropad ? "Macropad: on (numpad is S13–S30)" : "Macropad: off (numpad is numeric)",
            action: #selector(toggleMacropad)
        )
        pad.state = config.currentProfile.macropad ? .on : .off
        menu.addItem(pad)
        switch injector.cruiseState {
        case .off:
            menu.addItem(menuItem("Cruise Control: off", enabled: false))
        case .armed:
            menu.addItem(menuItem("Cruise Control: armed — tap a key to hold it", enabled: false))
        case .repeating:
            menu.addItem(menuItem("Cruise Control: repeating — tap cruise or the key to stop", enabled: false))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Edit config…", action: #selector(editConfig)))
        menu.addItem(menuItem("Reload config", action: #selector(reloadConfig)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Sidewinder X6", action: #selector(quit)))
        statusItem.menu = menu
        if statusItem.button?.image == nil, let image = statusIcon() {
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageLeading
        }
        statusItem.button?.title = device.isConnected ? "\(config.profile)" : ""
        statusItem.button?.toolTip = device.isConnected
            ? "Sidewinder X6 — profile \(config.profile)"
            : "Sidewinder X6 — disconnected"
    }

    private func menuItem(_ title: String, action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.isEnabled = enabled
        return item
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        injector.releaseAll()
        lastMask = 0
        config.setProfile(sender.tag)
        persistAndApply()
    }

    @objc private func toggleMacropad() {
        config.toggleMacropad()
        persistAndApply()
    }

    @objc private func editConfig() {
        try? config.save(to: configURL)
        NSWorkspace.shared.open(configURL)
    }

    @objc private func reloadConfig() {
        config = Config.loadOrCreate(url: configURL)
        persistAndApply()
        log("reloaded \(configURL.path)")
    }

    @objc private func grantAccess() {
        _ = injector.promptTrustIfNeeded()
        if let url = URL(string: "x-apple.systemsettings:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func log(_ message: String) {
        let line = "sidewinder-x6: \(message)\n"
        fputs(line, stderr)
        let url = Config.supportDirectory().appendingPathComponent("sidewinder-x6.log")
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: Config.supportDirectory(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
