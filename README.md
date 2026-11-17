# superduper

A single small, dependency-free macOS binary that gives you three features from [jasonrudolph/keyboard](https://github.com/jasonrudolph/keyboard)'s Karabiner-Elements + Hammerspoon setup:

1. **Caps lock:** tap for <kbd>escape</kbd>, hold for <kbd>control</kbd>
2. **(S)uper (D)uper mode:** hold <kbd>s</kbd>+<kbd>d</kbd> for vim-style navigation
3. **Window Layout mode:** <kbd>control</kbd>+<kbd>s</kbd>, then one key to arrange the focused window

It's meant for machines where installing Karabiner's virtual HID driver and a Lua scripting runtime (Hammerspoon) isn't acceptable, such as a locked-down work laptop.

## Why it's small enough to trust

| | Karabiner + Hammerspoon | superduper |
|---|---|---|
| Code you install | Two large apps, a driver extension, and a Lua runtime | ~750 lines of Swift you build yourself |
| Third-party dependencies | Many | **None.** Only Apple frameworks that ship with macOS |
| Permissions | Driver extension, Input Monitoring (several processes), Accessibility | **Accessibility only**, for one binary |
| Network access | Yes (update checks) | **None** |
| Reads or writes files | Config files, logs | **None.** launchd writes a few startup lines of stderr to a log |
| Runs other programs | Yes (Lua can run anything) | **None** |
| Configuration | JSON and Lua, loaded at runtime | **None.** Bindings are compiled in |

What the process touches, and nothing else:

- **A keyboard event tap.** It sees key events so it can remap them. It never logs or stores them. Like every tap, it gets nothing while a password field (secure input) is focused.
- **The focused window's position and size**, through the Accessibility API, and only when you trigger a window action.
- **The `UserKeyMapping` HID property** of attached keyboards, set to caps lock → right control. This is the same public API `/usr/bin/hidutil` uses. It's removed when superduper exits and never persists across reboots.
- **A small on-screen label** while Window Layout mode is active.

You can check this yourself:

```sh
wc -l Sources/*.swift                       # the whole program
make && otool -L build/superduper           # links only /System/Library and /usr/lib
nm -u build/superduper | grep -v '^_\$s' | grep -iE 'socket|connect|exec|spawn|popen|fopen|NSURL'   # no output expected
```

macOS ties the Accessibility grant to the binary's code hash (it's ad-hoc signed when you build). If the installed binary is modified in any way, macOS stops honoring the grant.

## Install

Build on the machine you'll run it on. You need the Xcode Command Line Tools with a Swift 6 toolchain (`xcode-select --install`).

```sh
git clone https://github.com/anglinb/superduper.git
cd superduper
make install      # runs the tests, builds, installs to ~/.local/bin, starts a LaunchAgent
```

Then go to **System Settings → Privacy & Security → Accessibility** and turn on **superduper**. It starts working within about 2 seconds; no restart needed.

Notes:

- superduper refuses to run from a terminal. Started from a shell, the Accessibility prompt would be for your *terminal app*, and approving it would give every command you run there control of your machine. Under launchd, the grant applies only to this binary.
- After any rebuild (`make install` again), the old Accessibility entry no longer matches. Remove it with **−** and turn on the new one.
- Quit Karabiner-Elements and Hammerspoon first if you use them, and leave **System Settings → Keyboard → Keyboard Shortcuts → Modifier Keys → Caps Lock** at its default, so two remappers don't fight.

Other commands: `make status`, `make restart`, `make test`, `make uninstall`.

## Usage

### Caps lock

- Tap <kbd>caps lock</kbd> (release within 150ms, no other key pressed) for <kbd>escape</kbd>
- Hold <kbd>caps lock</kbd> for <kbd>control</kbd>

### (S)uper (D)uper mode

Press <kbd>s</kbd> and <kbd>d</kbd> together (within 50ms) and keep holding them:

| Key | Action |
|---|---|
| <kbd>h</kbd> <kbd>j</kbd> <kbd>k</kbd> <kbd>l</kbd> | ← ↓ ↑ → |
| <kbd>a</kbd> | <kbd>option</kbd>. So <kbd>a</kbd>+<kbd>j</kbd>/<kbd>k</kbd> = page down/up and <kbd>a</kbd>+<kbd>h</kbd>/<kbd>l</kbd> = previous/next word |
| <kbd>f</kbd> | <kbd>command</kbd> |
| <kbd>space</kbd> | <kbd>shift</kbd>, for selecting while you move |
| <kbd>i</kbd> / <kbd>o</kbd> | previous / next tab (⌘⇧[ / ⌘⇧]) |
| <kbd>u</kbd> / <kbd>p</kbd> | first / last tab (⌘1 / ⌘9) |

### Window Layout mode

Press <kbd>control</kbd>+<kbd>s</kbd> (that is, <kbd>caps lock</kbd>+<kbd>s</kbd>). A label appears in the bottom-right corner. Then press one key:

| Key | Window goes to |
|---|---|
| <kbd>h</kbd> <kbd>j</kbd> <kbd>k</kbd> <kbd>l</kbd> | left / bottom / top / right half |
| <kbd>⇧h</kbd> / <kbd>⇧l</kbd> | left 40% / right 60% |
| <kbd>i</kbd> <kbd>o</kbd> <kbd>,</kbd> <kbd>.</kbd> | upper-left / upper-right / lower-left / lower-right quarter |
| <kbd>space</kbd> | centered, 60% wide, full height |
| <kbd>return</kbd> | fill the screen |
| <kbd>n</kbd> | next display |
| <kbd>←</kbd> / <kbd>→</kbd> | display to the left / right |
| <kbd>esc</kbd>, a <kbd>caps lock</kbd> tap, or <kbd>control</kbd>+<kbd>s</kbd> | cancel |

## Credit

The design of these bindings comes from Jason Rudolph's [keyboard](https://github.com/jasonrudolph/keyboard) setup (MIT licensed). That setup in turn credits Steve Losh's [Modern Space Cadet](http://stevelosh.com/blog/2012/10/a-modern-space-cadet), Karabiner's Simultaneous vi Mode, and [arbelt](https://github.com/arbelt) and [jasoncodes](https://github.com/jasoncodes) for the control/escape implementation. superduper is a from-scratch reimplementation and contains no code from it.

## Differences from the Karabiner/Hammerspoon version

- **Only the caps lock key sends escape on tap.** Caps lock becomes *right* control, and tap-for-escape applies only to that key. In the original, tapping the physical control key also sent escape.
- **Window Layout mode always exits after one key.** A key that isn't a binding cancels the mode and is swallowed. In the original, it typed into the window and left the mode on. <kbd>esc</kbd> and a caps lock tap also cancel.
- **Quarters and the centered layout stay below the menu bar.** They use the visible screen area, like the halves do. The original used the full screen for those layouts.
- **Keys mean physical positions,** which matters only on non-QWERTY layouts.
- **Not included:** the hyper key, Markdown mode, iTerm pane shortcuts, delete-word shortcuts, and the app-specific Karabiner rules.

## Customizing

All bindings are tables near the top of [`Sources/Engine.swift`](Sources/Engine.swift) (`superDuperBindings`, `windowBindings`), and the timing thresholds are in `Tuning`. Edit them, run `make install`, and allow the rebuilt binary in Accessibility settings. Window layouts are in [`Sources/Geometry.swift`](Sources/Geometry.swift).

## Troubleshooting

- **Nothing happens:** run `make status`. If the log says it's waiting for permission, allow it in Accessibility settings. After a rebuild, remove the old entry first.
- **Arrow keys stuck after typing:** if focus moves into a password field while you're holding <kbd>s</kbd>+<kbd>d</kbd>, macOS hides the key release from all event taps. Tap <kbd>s</kbd> or <kbd>d</kbd> once to leave the mode.
- **Newly plugged-in keyboard:** its first caps lock press acts as a normal caps lock. That press is how superduper notices the new keyboard and maps it. Tap caps lock once more to turn caps lock off; from then on it's control/escape.
- **Password fields:** super-duper mode and tap-for-escape don't work while a password field is focused, by design (macOS secure input). Caps lock still works as control there, because that remap happens at the HID level.

## Layout

```
Sources/Engine.swift     Key state machine. Pure: no OS calls, fully unit-tested.
Sources/Geometry.swift   Window layout math. Pure, fully unit-tested.
Sources/main.swift       macOS wiring: event tap, Accessibility, HID remap, mode label.
Tests/main.swift         Tests for Engine and Geometry (`make test`, no XCTest needed).
local.superduper.plist   LaunchAgent template.
```

## License

MIT. See [LICENSE](LICENSE).
