import ApplicationServices
import CoreGraphics
import Foundation

final class Injector {
    private var held: [String: Held] = [:]
    private let source = CGEventSource(stateID: .hidSystemState)
    private var cruiseArmed = false
    private var cruiseRepeating: Held?
    private var cruiseTimer: Timer?
    private var cruiseTap: CFMachPort?
    private var cruiseTapSource: CFRunLoopSource?
    private var cruiseInjecting = false
    private var cruiseCancelRelease = false

    private struct Held {
        var key: CGKeyCode
        var flags: CGEventFlags
    }

    enum CruiseState: String {
        case off
        case armed
        case repeating
    }

    var cruiseState: CruiseState {
        if cruiseRepeating != nil { return .repeating }
        if cruiseArmed { return .armed }
        return .off
    }

    var onCruiseChange: (() -> Void)?

    var trusted: Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func promptTrustIfNeeded() -> Bool {
        if trusted { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func press(id: String, binding: Config.Binding) {
        if let action = binding.action {
            handleAction(action, id: id, down: true)
        }
        if let text = binding.text, !text.isEmpty {
            type(text)
            return
        }
        if let name = binding.key, let code = KeyName.code(for: name) {
            let flags = KeyName.flags(from: binding.modifiers)
            post(code, flags: flags, down: true)
            held[id] = Held(key: code, flags: flags)
        }
    }

    func release(id: String, binding: Config.Binding) {
        if let held = held.removeValue(forKey: id) {
            post(held.key, flags: held.flags, down: false)
        }
        if let action = binding.action {
            handleAction(action, id: id, down: false)
        }
        if let shell = binding.shell, !shell.isEmpty {
            runShell(shell)
        }
        if let target = binding.open, !target.isEmpty {
            open(target)
        }
    }

    func releaseAll() {
        for (id, held) in held {
            post(held.key, flags: held.flags, down: false)
            _ = id
        }
        held.removeAll()
        stopCruise()
        cruiseArmed = false
    }

    func cruisePressed() {
        if cruiseRepeating != nil || cruiseArmed {
            stopCruise()
            cruiseCancelRelease = true
            return
        }
        cruiseArmed = true
        installCruiseTap()
        onCruiseChange?()
    }

    func cruiseReleased() {
        if cruiseCancelRelease {
            cruiseCancelRelease = false
        }
    }

    func stopCruise() {
        cruiseTimer?.invalidate()
        cruiseTimer = nil
        if let repeating = cruiseRepeating {
            cruiseInjecting = true
            post(repeating.key, flags: repeating.flags, down: false)
            cruiseInjecting = false
        }
        cruiseRepeating = nil
        cruiseArmed = false
        onCruiseChange?()
    }

    var onAction: ((String) -> Void)?

    private func handleAction(_ action: String, id: String, down: Bool) {
        guard !down else { return }
        onAction?(action)
    }

    private func post(_ key: CGKeyCode, flags: CGEventFlags, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func type(_ text: String) {
        guard let source else { return }
        var utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func runShell(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            fputs("sidewinder-x6: shell failed: \(error)\n", stderr)
        }
    }

    private func open(_ target: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if target.hasPrefix("-") || !target.contains("/") {
            process.arguments = ["-a", target]
        } else {
            process.arguments = [target]
        }
        do { try process.run() } catch {
            fputs("sidewinder-x6: open failed: \(error)\n", stderr)
        }
    }

    private func installCruiseTap() {
        guard cruiseTap == nil, trusted else { return }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                let injector = Unmanaged<Injector>.fromOpaque(refcon!).takeUnretainedValue()
                return injector.handleCruiseTap(proxy: proxy, type: type, event: event)
            },
            userInfo: ctx
        ) else {
            fputs("sidewinder-x6: cruise event tap failed (Accessibility?)\n", stderr)
            return
        }
        cruiseTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        cruiseTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleCruiseTap(
        proxy _: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let cruiseTap {
                CGEvent.tapEnable(tap: cruiseTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        if cruiseInjecting { return Unmanaged.passUnretained(event) }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return Unmanaged.passUnretained(event)
        }
        let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if let repeating = cruiseRepeating, key == repeating.key {
            stopCruise()
            return nil
        }
        if cruiseArmed, cruiseRepeating == nil {
            startCruiseRepeat(key: key, flags: event.flags)
            return Unmanaged.passUnretained(event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func startCruiseRepeat(key: CGKeyCode, flags: CGEventFlags) {
        cruiseTimer?.invalidate()
        cruiseTimer = nil
        cruiseArmed = false
        cruiseRepeating = Held(key: key, flags: flags)
        cruiseTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            guard let self, let repeating = self.cruiseRepeating else { return }
            self.cruiseInjecting = true
            if let event = CGEvent(keyboardEventSource: self.source, virtualKey: repeating.key, keyDown: true) {
                event.flags = repeating.flags
                event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
                event.post(tap: .cghidEventTap)
            }
            self.cruiseInjecting = false
        }
        onCruiseChange?()
    }
}
