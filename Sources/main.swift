import AppKit
import Foundation

let version = "1.0.0"

struct Options {
    var debug = false
    var listenOnly = false
    var printHelp = false
    var printVersion = false
    var configPath: String?
}

func parseOptions() -> Options {
    var options = Options()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "-h", "--help":
            options.printHelp = true
        case "-v", "--version":
            options.printVersion = true
        case "-d", "--debug":
            options.debug = true
        case "-l", "--listen":
            options.listenOnly = true
            options.debug = true
        case "--config":
            options.configPath = iterator.next()
        default:
            if arg.hasPrefix("--config=") {
                options.configPath = String(arg.dropFirst("--config=".count))
            } else {
                fputs("sidewinder-x6: unknown argument \(arg)\n", stderr)
                options.printHelp = true
            }
        }
    }
    return options
}

func printHelp() {
    let text = """
    Sidewinder X6 for macOS \(version)

    Usage: SidewinderX6 [--debug] [--listen] [--config PATH]

      --debug     Print HID reports and key events to stderr
      --listen    Report S-keys without injecting keystrokes
      --config    Config JSON path (default: ~/Library/Application Support/SidewinderX6/config.json)

    The S1–S6 keys, S-shift layer (S7–S12), optional macropad (S13–S30),
    bank switch, Game Center, and Macro buttons are handled here. Standard
    typing and media/volume keys stay with macOS.

    Default S1–S8 map to F13–F20. Edit the config JSON to change bindings.
    """
    print(text)
}

let options = parseOptions()
if options.printHelp {
    printHelp()
    exit(0)
}
if options.printVersion {
    print(version)
    exit(0)
}

let configURL = options.configPath.map { URL(fileURLWithPath: $0) } ?? Config.defaultConfigURL()
let app = NSApplication.shared
let delegate = SidewinderApp(configURL: configURL, debug: options.debug, listenOnly: options.listenOnly)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
