import Foundation
import CoreGraphics

struct Config: Codable {
    var profile: Int
    var profiles: [Profile]

    struct Profile: Codable {
        var name: String
        var macropad: Bool
        var keys: [String: Binding]
    }

    struct Binding: Codable {
        var key: String?
        var modifiers: [String]?
        var text: String?
        var shell: String?
        var open: String?
        var action: String?
    }

    static let defaultProfileCount = 3

    static func load(from url: URL) throws -> Config {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    var currentProfileIndex: Int {
        max(0, min(Self.defaultProfileCount - 1, profile - 1))
    }

    var currentProfile: Profile {
        let index = currentProfileIndex
        if index < profiles.count { return profiles[index] }
        return Self.makeDefault().profiles[index]
    }

    mutating func setProfile(_ oneBased: Int) {
        profile = ((oneBased - 1) % Self.defaultProfileCount) + 1
        if profile < 1 { profile = Self.defaultProfileCount }
    }

    mutating func cycleProfile() {
        setProfile(profile + 1)
    }

    mutating func toggleMacropad() {
        let index = currentProfileIndex
        ensureProfileSlots()
        profiles[index].macropad.toggle()
    }

    mutating func ensureProfileSlots() {
        while profiles.count < Self.defaultProfileCount {
            var next = Self.defaultProfile(named: "Profile \(profiles.count + 1)", macropad: profiles.count > 0)
            if profiles.count == 0 { next = Self.defaultProfile(named: "Profile 1", macropad: false) }
            profiles.append(next)
        }
    }

    static func supportDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return root.appendingPathComponent("SidewinderX6", isDirectory: true)
    }

    static func defaultConfigURL() -> URL {
        supportDirectory().appendingPathComponent("config.json")
    }

    static func loadOrCreate(url: URL = defaultConfigURL()) -> Config {
        if let loaded = try? load(from: url) {
            var config = loaded
            config.ensureProfileSlots()
            if config.profile < 1 || config.profile > defaultProfileCount { config.profile = 1 }
            if config.migrateSpecials() {
                try? config.save(to: url)
            }
            return config
        }
        let created = makeDefault()
        try? created.save(to: url)
        return created
    }

    /// Fix first-release bindings: Game Center was Calculator, Macro toggled macropad.
    @discardableResult
    mutating func migrateSpecials() -> Bool {
        let calc = "/System/Applications/Calculator.app"
        var changed = false
        for i in profiles.indices {
            if profiles[i].keys["GameCenter"]?.open == calc {
                profiles[i].keys["GameCenter"] = Binding(action: "none")
                changed = true
            }
            if profiles[i].keys["Calculator"] == nil {
                profiles[i].keys["Calculator"] = Binding(open: calc)
                changed = true
            }
            if profiles[i].keys["Macro"]?.action == "toggle-macropad" {
                profiles[i].keys["Macro"] = Binding(action: "none")
                changed = true
            }
            if profiles[i].keys["Cruise"] == nil {
                profiles[i].keys["Cruise"] = Binding(action: "cruise")
                changed = true
            }
            if profiles[i].keys["Bank"] == nil {
                profiles[i].keys["Bank"] = Binding(action: "next-profile")
                changed = true
            }
        }
        return changed
    }

    static func makeDefault() -> Config {
        Config(
            profile: 1,
            profiles: [
                defaultProfile(named: "Profile 1", macropad: false),
                defaultProfile(named: "Profile 2", macropad: true),
                defaultProfile(named: "Profile 3", macropad: true)
            ]
        )
    }

    static func defaultProfile(named name: String, macropad: Bool) -> Profile {
        var keys: [String: Binding] = [
            "Bank": Binding(action: "next-profile"),
            "Calculator": Binding(open: "/System/Applications/Calculator.app"),
            "GameCenter": Binding(action: "none"),
            "Macro": Binding(action: "none"),
            "Cruise": Binding(action: "cruise")
        ]
        // S1-S8 → F13-F20. Remaining S-keys get unique modifier chords so they are bindable.
        let fKeys = ["f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20"]
        for i in 1...8 {
            keys["S\(i)"] = Binding(key: fKeys[i - 1])
        }
        for i in 9...12 {
            keys["S\(i)"] = Binding(key: fKeys[i - 9], modifiers: ["shift"])
        }
        for i in 13...20 {
            keys["S\(i)"] = Binding(key: fKeys[i - 13], modifiers: ["option"])
        }
        for i in 21...28 {
            keys["S\(i)"] = Binding(key: fKeys[i - 21], modifiers: ["control"])
        }
        keys["S29"] = Binding(key: "f19", modifiers: ["shift"])
        keys["S30"] = Binding(key: "f20", modifiers: ["shift"])
        return Profile(name: name, macropad: macropad, keys: keys)
    }
}

enum KeyName {
    static let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53,
        "command": 55, "shift": 56, "capslock": 57, "option": 58, "control": 59,
        "rightshift": 60, "rightoption": 61, "rightcontrol": 62, "function": 63,
        "f17": 64, "volumeup": 72, "volumedown": 73, "mute": 74, "f18": 79, "f19": 80,
        "f20": 90, "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101,
        "f11": 103, "f13": 105, "f16": 106, "f14": 107, "f10": 109, "f12": 111,
        "f15": 113, "help": 114, "home": 115, "pageup": 116, "forwarddelete": 117,
        "f4": 118, "end": 119, "f2": 120, "pagedown": 121, "f1": 122, "left": 123,
        "right": 124, "down": 125, "up": 126,
        "keypadclear": 71, "keypadequals": 81, "keypaddivide": 75, "keypadmultiply": 67,
        "keypadminus": 78, "keypadplus": 69, "keypadenter": 76, "keypaddecimal": 65,
        "keypad0": 82, "keypad1": 83, "keypad2": 84, "keypad3": 85, "keypad4": 86,
        "keypad5": 87, "keypad6": 88, "keypad7": 89, "keypad8": 91, "keypad9": 92
    ]

    static func code(for name: String) -> CGKeyCode? {
        codes[name.lowercased()]
    }

    static func flags(from names: [String]?) -> CGEventFlags {
        guard let names else { return [] }
        var flags: CGEventFlags = []
        for name in names {
            switch name.lowercased() {
            case "shift": flags.insert(.maskShift)
            case "control", "ctrl": flags.insert(.maskControl)
            case "option", "alt": flags.insert(.maskAlternate)
            case "command", "cmd": flags.insert(.maskCommand)
            case "fn", "function": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }
}
