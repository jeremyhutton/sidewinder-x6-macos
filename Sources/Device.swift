import Foundation
import IOKit
import IOKit.hid

protocol SidewinderDelegate: AnyObject {
    func sidewinderConnected()
    func sidewinderDisconnected()
    func sidewinderMacroChanged(mask: UInt32)
    func sidewinderSpecial(_ special: SidewinderSpecial, pressed: Bool)
}

enum SidewinderSpecial: String {
    case bank = "Bank"
    case gameCenter = "GameCenter"
    case macro = "Macro"
    case cruise = "Cruise"
    case calculator = "Calculator"
}

final class SidewinderDevice {
    static let vendorID = 0x045E
    static let productID = 0x074B
    static let consumerUsagePage = 0x0C
    static let consumerUsage = 0x01
    static let featureReportID: CFIndex = 7
    static let macroReportID: UInt32 = 8
    static let mediaReportID: UInt32 = 1

    weak var delegate: SidewinderDelegate?
    var debug = false
    var onLog: ((String) -> Void)?

    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var reportBufferSize = 0
    private var lastMacroMask: UInt32 = 0
    private var lastVendor: UInt8 = 0
    private var lastConsumer: UInt16 = 0
    private var lastReport10: UInt8 = 0
    private var specialDown: Set<SidewinderSpecial> = []
    private var ignoreSpecialsUntil: TimeInterval = 0
    private static let mediaConsumers: Set<UInt16> = [
        0x00B5, 0x00B6, 0x00B7, 0x00B8, 0x00CD, 0x00E2, 0x00E9, 0x00EA
    ]

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        stop()
        if let reportBuffer {
            reportBuffer.deallocate()
        }
    }

    func start() {
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
            kIOHIDPrimaryUsagePageKey as String: Self.consumerUsagePage,
            kIOHIDPrimaryUsageKey as String: Self.consumerUsage
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<SidewinderDevice>.fromOpaque(context!).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<SidewinderDevice>.fromOpaque(context!).takeUnretainedValue().detach(device)
        }, ctx)
        IOHIDManagerSetInputValueMatching(manager, [
            kIOHIDElementUsagePageKey as String: 0xFF00
        ] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess else { return }
            Unmanaged<SidewinderDevice>.fromOpaque(context!).takeUnretainedValue().handleValue(value)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let open = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if open != kIOReturnSuccess {
            fputs(String(format: "sidewinder-x6: IOHIDManagerOpen failed 0x%08x\n", UInt32(bitPattern: open)), stderr)
        }
        if let existing = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            existing.forEach(attach)
        }
    }

    func stop() {
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            self.device = nil
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    var isConnected: Bool { device != nil }

    func apply(profileIndex: Int, macropad: Bool) {
        guard let device else { return }
        let profile = max(0, min(2, profileIndex))
        var leds = UInt8(1 << (profile + 2))
        if macropad { leds |= 0x01 }
        var payload: [UInt8] = [0x07, leds]
        let result = payload.withUnsafeMutableBufferPointer { ptr in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, Self.featureReportID, ptr.baseAddress!, 2)
        }
        ignoreSpecialsUntil = ProcessInfo.processInfo.systemUptime + 0.25
        if debug || result != kIOReturnSuccess {
            fputs(
                String(
                    format: "sidewinder-x6: SET feature 7 leds=0x%02x -> 0x%08x\n",
                    leds,
                    UInt32(bitPattern: result)
                ),
                stderr
            )
        }
    }

    private func attach(_ hid: IOHIDDevice) {
        if device != nil { return }
        let open = IOHIDDeviceOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        guard open == kIOReturnSuccess else {
            fputs(String(format: "sidewinder-x6: IOHIDDeviceOpen failed 0x%08x\n", UInt32(bitPattern: open)), stderr)
            return
        }
        device = hid
        lastMacroMask = 0
        lastVendor = 0
        lastConsumer = 0
        lastReport10 = 0
        specialDown.removeAll()

        let maxSize = (IOHIDDeviceGetProperty(hid, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 8
        let size = max(maxSize, 8)
        if reportBufferSize != size {
            reportBuffer?.deallocate()
            reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            reportBufferSize = size
        }
        reportBuffer?.initialize(repeating: 0, count: size)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(hid, reportBuffer!, size, { context, result, _, type, reportID, report, length in
            guard result == kIOReturnSuccess else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
            Unmanaged<SidewinderDevice>.fromOpaque(context!).takeUnretainedValue()
                .handleReport(type: type, reportID: reportID, bytes: bytes)
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        delegate?.sidewinderConnected()
    }

    private func detach(_ hid: IOHIDDevice) {
        guard device === hid || device == hid else { return }
        IOHIDDeviceUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        device = nil
        lastMacroMask = 0
        lastVendor = 0
        lastConsumer = 0
        lastReport10 = 0
        specialDown.removeAll()
        delegate?.sidewinderDisconnected()
    }

    private func handleReport(type: IOHIDReportType, reportID: UInt32, bytes: [UInt8]) {
        if debug {
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            fputs("sidewinder-x6: report id=\(reportID) type=\(type.rawValue) [\(hex)]\n", stderr)
        }
        switch reportID {
        case Self.macroReportID:
            handleMacro(bytes)
        case Self.mediaReportID:
            handleSpecial(bytes)
        case 10:
            handleReport10(bytes)
        default:
            if bytes.contains(where: { $0 != 0 }) {
                logHID("ignored id=\(reportID) [\(hexBytes(bytes))]")
            }
        }
    }

    private func handleValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        guard page == 0xFF00 else { return }
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        if debug {
            fputs(String(format: "sidewinder-x6: value usage=0x%04x pressed=%d\n", usage, pressed ? 1 : 0), stderr)
        }
        // S-keys only. Special keys are parsed from raw report 1 so Bank cannot fire twice.
        if usage >= 0xFB01 && usage <= 0xFB1E {
            let bit = usage - 0xFB01
            let bitMask = UInt32(1) << bit
            let next = pressed ? (lastMacroMask | bitMask) : (lastMacroMask & ~bitMask)
            guard next != lastMacroMask else { return }
            lastMacroMask = next
            delegate?.sidewinderMacroChanged(mask: next)
        }
    }

    private func handleMacro(_ bytes: [UInt8]) {
        let payload: ArraySlice<UInt8>
        if bytes.first == UInt8(Self.macroReportID) {
            payload = bytes.dropFirst()
        } else {
            payload = bytes[...]
        }
        guard payload.count >= 4 else { return }
        let mask =
            UInt32(payload[payload.startIndex]) |
            UInt32(payload[payload.startIndex + 1]) << 8 |
            UInt32(payload[payload.startIndex + 2]) << 16 |
            UInt32(payload[payload.startIndex + 3]) << 24
        lastMacroMask = mask
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.sidewinderMacroChanged(mask: mask)
        }
    }

    private func handleSpecial(_ bytes: [UInt8]) {
        let payload = bytes.first == UInt8(Self.mediaReportID) ? Array(bytes.dropFirst()) : bytes
        // Report 1: 16-bit consumer, 24-bit pad, 8-bit vendor array, 8-bit vendor var.
        guard payload.count >= 6 else { return }
        let consumer = UInt16(payload[0]) | UInt16(payload[1]) << 8
        let vendor = payload[5]
        let extra = payload.count > 6 ? payload[6] : 0
        let interesting = (vendor != 0 && vendor != lastVendor)
            || (consumer != 0 && !Self.mediaConsumers.contains(consumer) && consumer != lastConsumer)
            || extra != 0
        if interesting {
            logHID(String(format: "report1 consumer=0x%04x vendor=0x%02x extra=0x%02x [%@]", consumer, vendor, extra, hexBytes(bytes)))
        }
        if ProcessInfo.processInfo.systemUptime < ignoreSpecialsUntil { return }
        applyConsumer(consumer)
        applyVendorByte(vendor)
    }

    private func handleReport10(_ bytes: [UInt8]) {
        let payload = bytes.first == 10 ? Array(bytes.dropFirst()) : bytes
        let value = payload.first ?? 0
        if value != lastReport10 {
            logHID(String(format: "report10 value=0x%02x [%@]", value, hexBytes(bytes)))
        }
        if ProcessInfo.processInfo.systemUptime < ignoreSpecialsUntil { return }
        if value == lastReport10 { return }
        lastReport10 = value
        emitSpecial(.cruise, pressed: value != 0)
    }

    private func applyConsumer(_ consumer: UInt16) {
        if consumer == lastConsumer { return }
        let previous = lastConsumer
        lastConsumer = consumer
        mapConsumer(previous, pressed: false)
        mapConsumer(consumer, pressed: true)
    }

    private func mapConsumer(_ value: UInt16, pressed: Bool) {
        guard value != 0, !Self.mediaConsumers.contains(value) else { return }
        if value == 0x0192 {
            emitSpecial(.calculator, pressed: pressed)
        } else {
            logHID(String(format: "unmapped consumer 0x%04x pressed=%d", value, pressed ? 1 : 0))
        }
    }

    private func applyVendorByte(_ vendor: UInt8) {
        if vendor == lastVendor { return }
        let previous = lastVendor
        lastVendor = vendor
        mapVendor(previous, pressed: false)
        mapVendor(vendor, pressed: true)
    }

    private func mapVendor(_ value: UInt8, pressed: Bool) {
        guard value != 0 else { return }
        let special: SidewinderSpecial
        switch value {
        case 0x10: special = .gameCenter
        case 0x11: special = .macro
        case 0x14: special = .bank
        default: special = .cruise
        }
        emitSpecial(special, pressed: pressed)
    }

    private func hexBytes(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func logHID(_ message: String) {
        onLog?(message)
        if debug {
            fputs("sidewinder-x6: \(message)\n", stderr)
        }
    }

    private func emitSpecial(_ special: SidewinderSpecial, pressed: Bool) {
        if pressed {
            if specialDown.contains(special) { return }
            specialDown.insert(special)
        } else {
            if !specialDown.contains(special) { return }
            specialDown.remove(special)
        }
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.sidewinderSpecial(special, pressed: pressed)
        }
    }
}
