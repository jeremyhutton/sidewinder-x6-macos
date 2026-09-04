# Sidewinder X6 for macOS

Userspace driver for the Microsoft SideWinder X6 so the macro keys work on macOS.

The main typing keys and media/volume cluster already work through Apple's HID stack. This app opens the keyboard's **consumer/vendor** HID collection (the one macOS ignores) and:

- Reads S1–S30 as a 32-bit bitmask (HID report 8)
- Handles Bank, Game Center, Macro, Cruise, and Calculator (HID report 1)
- Sets profile LEDs and macropad mode (HID feature report 7)
- Injects bindable keystrokes (default: S1–S8 → F13–F20)

Protocol matches the Linux userspace driver ([Wattos/LinuxSidewinderX6](https://github.com/Wattos/LinuxSidewinderX6)) and the X6 report descriptor (`045e:074b`).

## Install

```bash
cd sidewinder-x6-macos
make install
```

That copies `SidewinderX6.app` to `/Applications`, writes a default config if you do not have one, and loads a LaunchAgent so it starts at login.

Then grant **Accessibility** once:

1. In the **X6** menu bar item, choose **Accessibility: click to grant** if it is not already allowed.
2. System Settings → Privacy & Security → Accessibility → enable **Sidewinder X6**.
3. Remove any duplicate/old Sidewinder X6 rows left over from earlier builds, then quit and reopen the app (or log out/in).

The app is signed with a stable bundle-id designated requirement (`com.vjh.sidewinder-x6`), so rebuilds should keep the grant. It is started through Launch Services (`open -a`), not as a raw launchd binary, so the slider matches the running process.

A menu bar item titled `X6` (or `X6·1` when the keyboard is plugged in) is the control surface.

## Keys

| Hardware | What it does here |
| --- | --- |
| S1–S6 | Left macro column |
| S-shift + S1–S6 | S7–S12 (firmware layer; no extra software needed) |
| Numpad in macropad mode | S13–S30, amber backlight |
| Bank (`123`) | Cycles profile 1 → 2 → 3 and updates the LEDs |
| Calculator (near numpad) | Opens Calculator |
| Game Center (SideWinder logo) | Unbound by default |
| Macro record | Unbound by default (bind it in config if you want) |
| Cruise Control (running man) | Arm, then tap a key to hold it; tap cruise or that key to stop |
| Volume / play / mute | Left to macOS |

Profile 1 starts with the numpad numeric. Profiles 2 and 3 start with macropad on, matching IntelliType's usual banks.

## Config

`~/Library/Application Support/SidewinderX6/config.json`

Reload from the menu bar after editing, or pick **Edit config…**. Unknown JSON fields are ignored; a missing field just means that effect is unused.

### File shape

```json
{
  "profile": 1,
  "profiles": [
    {
      "name": "Profile 1",
      "macropad": false,
      "keys": {
        "S1": { "key": "f13" },
        "Bank": { "action": "next-profile" }
      }
    }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `profile` | Last selected bank, `1`–`3`. The Bank key updates this. |
| `profiles` | Three banks. Extra entries are unused; missing ones are filled in. |
| `name` | Label in the menu bar. |
| `macropad` | `true` = numpad is S13–S30 (amber). `false` = numeric keypad. |
| `keys` | Map of **hardware name → binding**. |

### Hardware names (the `keys` object)

| Name | Physical key |
| --- | --- |
| `S1` … `S6` | Left column |
| `S7` … `S12` | S-shift + S1–S6 (firmware layer) |
| `S13` … `S30` | Numpad, only while that profile has `macropad: true` |
| `Bank` | `123` profile cycle |
| `Calculator` | Calculator key by the numpad |
| `GameCenter` | SideWinder logo |
| `Macro` | Record-macro button |
| `Cruise` | Running-man key. The physical cruise button always arms cruise control; this entry is only used if you also bind `action: "cruise"` on some other key. |

### Binding fields

All fields are optional. You can combine them on one key.

| Field | When it runs | What it does |
| --- | --- | --- |
| `key` | Held for as long as the hardware key is down | Injects one named key (see list below). Not a character to type. |
| `modifiers` | With `key` | Extra modifier flags on that keystroke. |
| `text` | On **press** | Types this string as Unicode. If present, `key` is skipped. |
| `action` | On **release** | Built-in driver command. |
| `shell` | On **release** | Runs `zsh -lc '<command>'`. |
| `open` | On **release** | Opens a file, app, or URL. |

Example mix: hold ⌘C while S1 is down, and on release open Notes:

```json
"S1": {
  "key": "c",
  "modifiers": ["command"],
  "open": "/System/Applications/Notes.app"
}
```

### `action`

| Value | Effect |
| --- | --- |
| `next-profile` | Bank 1 → 2 → 3 → 1, updates the keyboard LEDs |
| `prev-profile` | Opposite direction |
| `toggle-macropad` | Numpad numeric ↔ S13–S30 for the **current** profile |
| `cruise` | Same as the running-man key: arm, then the next key you type is held until you tap cruise or that key again |
| `none` | Do nothing |

Anything else is logged as `unknown action` and ignored.

### `key` — not special characters

`key` is a **named key on a US Mac keyboard**, looked up case-insensitively. You cannot put `å`, `⌘`, `F13`, or `ctrl+c` here. For arbitrary characters or strings, use `text`.

Letters and digits: `a`–`z`, `0`–`9`

Symbols: `` ` `` `-` `=` `[` `]` `\` `;` `'` `,` `.` `/`

Named keys:

```
return tab space delete escape
command shift option control function capslock
rightshift rightoption rightcontrol
f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
f13 f14 f15 f16 f17 f18 f19 f20
left right up down
home end pageup pagedown help forwarddelete
volumeup volumedown mute
keypad0 … keypad9
keypadclear keypadequals keypaddivide keypadmultiply
keypadminus keypadplus keypadenter keypaddecimal
```

There is no `f21`–`f24`. Unknown names are silently ignored (the rest of the binding still runs).

### `modifiers`

Array of names (case-insensitive):

| Name | Also accepted |
| --- | --- |
| `shift` | |
| `control` | `ctrl` |
| `option` | `alt` |
| `command` | `cmd` |
| `fn` | `function` |

These are flags on the `key` keystroke, not extra `key` entries.

```json
"S2": { "key": "v", "modifiers": ["command", "shift"] }
```

### `text`

UTF-8 string, typed on press. Use this for special characters, snippets, emoji, or anything that is not a single named key.

```json
"S3": { "text": "¯\\_(ツ)_/¯" }
"S4": { "text": "https://example.com\n" }
```

### `open`

- Path with a slash → `open /that/path` (apps, files, folders, `https://…` URLs)
- No slash (or starts with `-`) → `open -a Name` (app by name)

```json
"GameCenter": { "open": "/System/Applications/Notes.app" }
"S5": { "open": "Safari" }
"S6": { "open": "https://news.ycombinator.com" }
```

### `shell`

Run by `/bin/zsh -lc`. stdout/stderr are discarded. Runs as your user.

```json
"Macro": { "shell": "osascript -e 'display notification \"S-key\" with title \"Sidewinder\"'" }
"S7": { "shell": "open -a Music" }
```

Do not put secrets in here if you sync this file.

## Debug

```bash
/Applications/SidewinderX6.app/Contents/MacOS/SidewinderX6 --listen
```

Press S-keys and watch stderr. `--debug` logs raw HID reports while still injecting.

## Uninstall

```bash
make uninstall
```

Config is left in Application Support.