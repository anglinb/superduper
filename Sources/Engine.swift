// Engine.swift — the pure keyboard state machine.
//
// No OS calls happen here. The engine takes abstract key events and returns
// what to emit (pass the original through, or post synthetic keys) plus side
// effects (show/hide the window-mode HUD, move a window). main.swift turns
// those into real CGEvents and Accessibility calls. Keeping this pure means
// every behavior can be tested without granting any permissions.

import CoreGraphics

// MARK: - Key codes (macOS virtual key codes = physical ANSI positions)

enum Key {
    static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, f: UInt16 = 3, h: UInt16 = 4
    static let x: UInt16 = 7, c: UInt16 = 8
    static let one: UInt16 = 18, nine: UInt16 = 25
    static let closeBracket: UInt16 = 30, o: UInt16 = 31, u: UInt16 = 32
    static let openBracket: UInt16 = 33, i: UInt16 = 34, p: UInt16 = 35
    static let returnKey: UInt16 = 36, l: UInt16 = 37, j: UInt16 = 38, k: UInt16 = 40
    static let comma: UInt16 = 43, n: UInt16 = 45, period: UInt16 = 47
    static let space: UInt16 = 49, escape: UInt16 = 53
    static let capsLock: UInt16 = 57, leftControl: UInt16 = 59, rightControl: UInt16 = 62
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
}

// MARK: - Tunables

enum Tuning {
    /// Max gap between `s` and `d` key-downs to count as simultaneous.
    /// 50ms matches Karabiner-Elements' default `simultaneous_threshold_milliseconds`.
    static let simultaneousThreshold = 0.050
    /// Caps lock released within this window, with no key pressed in between, sends Escape.
    /// 150ms matches the original Hammerspoon control-escape.lua.
    static let escapeTapThreshold = 0.150
}

// MARK: - Types

enum KeyEventKind { case keyDown, keyUp, flagsChanged }

struct KeyEvent {
    var kind: KeyEventKind
    var code: UInt16
    var flags: CGEventFlags
    var isRepeat: Bool = false
    /// Seconds, monotonic.
    var time: Double
}

enum Emit: Equatable {
    /// Let the original event through with these flags.
    case original(flags: CGEventFlags)
    /// Post a synthetic key event.
    case synth(code: UInt16, down: Bool, flags: CGEventFlags, isRepeat: Bool)
}

enum Effect: Equatable {
    case windowMode(Bool)
    case window(WindowAction)
    /// A raw caps lock event was seen, meaning some keyboard (e.g., one just
    /// plugged in) lacks the caps→control mapping. Re-apply it.
    case reapplyCapsMapping
}

struct Output: Equatable {
    var emits: [Emit] = []
    var effects: [Effect] = []
    /// Ask the host to call `timerFired(token:)` after `delay` seconds.
    var timer: Timer? = nil

    struct Timer: Equatable { var token: Int; var delay: Double }
}

/// What a key does while (S)uper (D)uper mode is active.
enum Remap: Equatable {
    /// Emit a different key, adding these modifiers.
    case key(UInt16, CGEventFlags)
    /// Act as a held modifier.
    case modifier(CGEventFlags)
}

// MARK: - Bindings

let modifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
/// Real arrow key events carry these flags; some apps look for them.
let arrowFlags: CGEventFlags = [.maskNumericPad, .maskSecondaryFn]
/// Device-dependent bit set while the *right* control key is down (NX_DEVICERCTLKEYMASK).
let rightControlDownBit: UInt64 = 0x0000_2000

/// (S)uper (D)uper mode: hold `s` + `d`, then...
let superDuperBindings: [UInt16: Remap] = [
    Key.h: .key(Key.left, arrowFlags),
    Key.j: .key(Key.down, arrowFlags),
    Key.k: .key(Key.up, arrowFlags),
    Key.l: .key(Key.right, arrowFlags),
    Key.a: .modifier(.maskAlternate),                         // a = option (a+j/k = page down/up, a+h/l = word left/right)
    Key.f: .modifier(.maskCommand),                           // f = command
    Key.space: .modifier(.maskShift),                         // space = shift
    Key.u: .key(Key.one, .maskCommand),                       // first tab
    Key.i: .key(Key.openBracket, [.maskCommand, .maskShift]), // previous tab
    Key.o: .key(Key.closeBracket, [.maskCommand, .maskShift]),// next tab
    Key.p: .key(Key.nine, .maskCommand),                      // last tab
]

/// Window Layout mode: press ctrl+s, then one of these. Keyed by (code, shift held).
struct WindowKey: Hashable { var code: UInt16; var shift: Bool }

let windowBindings: [WindowKey: WindowAction] = [
    WindowKey(code: Key.returnKey, shift: false): .maximize,
    WindowKey(code: Key.space, shift: false): .center,
    WindowKey(code: Key.h, shift: false): .left,
    WindowKey(code: Key.j, shift: false): .down,
    WindowKey(code: Key.k, shift: false): .up,
    WindowKey(code: Key.l, shift: false): .right,
    WindowKey(code: Key.h, shift: true): .left40,
    WindowKey(code: Key.l, shift: true): .right60,
    WindowKey(code: Key.i, shift: false): .upLeft,
    WindowKey(code: Key.o, shift: false): .upRight,
    WindowKey(code: Key.comma, shift: false): .downLeft,
    WindowKey(code: Key.period, shift: false): .downRight,
    WindowKey(code: Key.n, shift: false): .nextScreen,
    WindowKey(code: Key.right, shift: false): .screenEast,
    WindowKey(code: Key.left, shift: false): .screenWest,
]

// MARK: - Engine

final class Engine {
    private enum SuperDuper: Equatable {
        case idle
        /// `s` or `d` is down and held back; waiting to see if its partner follows.
        case pending(code: UInt16, flags: CGEventFlags, time: Double, token: Int)
        case active
    }

    private var sd: SuperDuper = .idle
    private var timerToken = 0
    /// Keys whose key-down was remapped; their repeats/key-up follow the same remap.
    private var remapped: [UInt16: Remap] = [:]
    /// Keys whose key-down we swallowed; swallow the matching key-up too.
    private var swallowUp: Set<UInt16> = []
    /// Modifiers currently held via (S)uper (D)uper `a` / `f` / `space`.
    private var virtualMods: CGEventFlags = []

    private(set) var windowMode = false

    private var capsDownTime: Double? = nil
    private var escapeCandidate = false

    func handle(_ e: KeyEvent) -> Output {
        var out = Output()
        switch e.kind {
        case .flagsChanged: handleFlags(e, &out)
        case .keyDown: handleDown(e, &out)
        case .keyUp: handleUp(e, &out)
        }
        return out
    }

    func timerFired(token: Int) -> Output {
        var out = Output()
        if case let .pending(_, _, _, t) = sd, t == token { flushPending(&out) }
        return out
    }

    /// Forget all state, releasing any synthetic keys still held down.
    /// Called if the OS disables and we re-enable the event tap.
    func reset() -> Output {
        var out = Output()
        flushPending(&out)
        for (_, remap) in remapped.sorted(by: { $0.key < $1.key }) {
            if case let .key(code, flags) = remap {
                out.emits.append(.synth(code: code, down: false, flags: flags, isRepeat: false))
            }
        }
        if windowMode { out.effects.append(.windowMode(false)) }
        sd = .idle; remapped = [:]; swallowUp = []; virtualMods = []
        windowMode = false; capsDownTime = nil; escapeCandidate = false
        return out
    }

    // MARK: Modifier changes (caps lock → control / escape)

    private func handleFlags(_ e: KeyEvent, _ out: inout Output) {
        flushPending(&out)

        switch e.code {
        case Key.capsLock:
            out.effects.append(.reapplyCapsMapping)
            out.emits.append(.original(flags: e.flags))

        case Key.rightControl:
            let isDown = e.flags.rawValue & rightControlDownBit != 0
            out.emits.append(.original(flags: e.flags))
            if isDown {
                capsDownTime = e.time
                escapeCandidate = true
            } else {
                if escapeCandidate, let t = capsDownTime, e.time - t < Tuning.escapeTapThreshold {
                    if windowMode {
                        exitWindowMode(&out)
                    } else {
                        out.emits.append(.synth(code: Key.escape, down: true, flags: [], isRepeat: false))
                        out.emits.append(.synth(code: Key.escape, down: false, flags: [], isRepeat: false))
                    }
                }
                capsDownTime = nil
                escapeCandidate = false
            }

        default:
            out.emits.append(.original(flags: e.flags))
        }
    }

    // MARK: Key down

    private func handleDown(_ e: KeyEvent, _ out: inout Output) {
        escapeCandidate = false

        if e.isRepeat {
            if let remap = remapped[e.code] {
                emitRemap(remap, e, down: true, &out)
                return
            }
            if swallowUp.contains(e.code) { return }
        } else {
            // A fresh press supersedes stale state for this key (e.g., a key-up
            // that never arrived because the tap was briefly disabled).
            swallowUp.remove(e.code)
            if let stale = remapped.removeValue(forKey: e.code) { emitRemap(stale, e, down: false, &out) }
        }

        if windowMode {
            handleWindowModeKey(e, &out)
            return
        }

        if isControlS(e) {
            flushPending(&out)
            windowMode = true
            swallowUp.insert(e.code)
            out.effects.append(.windowMode(true))
            return
        }

        handleSuperDuperDown(e, &out)
    }

    private func handleSuperDuperDown(_ e: KeyEvent, _ out: inout Output) {
        switch sd {
        case let .pending(code, _, time, _):
            if e.code == partner(of: code), !e.isRepeat, hasNoModifiers(e),
               e.time - time <= Tuning.simultaneousThreshold {
                sd = .active
                timerToken += 1 // cancel the pending timer
                return
            }
            flushPending(&out)
            handleSuperDuperDown(e, &out) // now idle; re-evaluate (e.g., "ss" typed fast)

        case .active:
            if e.code == Key.s || e.code == Key.d { return } // holding the chord
            if let remap = superDuperBindings[e.code] {
                remapped[e.code] = remap
                emitRemap(remap, e, down: true, &out)
            } else {
                out.emits.append(.original(flags: e.flags.union(virtualMods)))
            }

        case .idle:
            if (e.code == Key.s || e.code == Key.d), !e.isRepeat, hasNoModifiers(e) {
                timerToken += 1
                sd = .pending(code: e.code, flags: e.flags, time: e.time, token: timerToken)
                out.timer = .init(token: timerToken, delay: Tuning.simultaneousThreshold)
                return
            }
            out.emits.append(.original(flags: e.flags.union(virtualMods)))
        }
    }

    // MARK: Key up

    private func handleUp(_ e: KeyEvent, _ out: inout Output) {
        if let remap = remapped.removeValue(forKey: e.code) {
            emitRemap(remap, e, down: false, &out)
            return
        }
        if swallowUp.remove(e.code) != nil { return }

        switch sd {
        case let .pending(code, _, _, _) where code == e.code:
            flushPending(&out)
            out.emits.append(.original(flags: e.flags.union(virtualMods)))
        case .active where e.code == Key.s || e.code == Key.d:
            // Releasing either key ends the mode; the partner's key-up is swallowed.
            sd = .idle
            swallowUp.insert(partner(of: e.code))
        default:
            out.emits.append(.original(flags: e.flags.union(virtualMods)))
        }
    }

    // MARK: Window Layout mode

    private func handleWindowModeKey(_ e: KeyEvent, _ out: inout Output) {
        // Every key press in this mode is consumed and ends the mode.
        swallowUp.insert(e.code)
        if e.isRepeat { return }
        exitWindowMode(&out)

        if isControlS(e) || e.code == Key.escape { return }
        let mods = e.flags.intersection(modifierMask)
        if mods.contains(.maskCommand) || mods.contains(.maskAlternate) { return }
        // Control is ignored so it doesn't matter if caps lock is still held.
        let key = WindowKey(code: e.code, shift: mods.contains(.maskShift))
        if let action = windowBindings[key] { out.effects.append(.window(action)) }
    }

    private func exitWindowMode(_ out: inout Output) {
        windowMode = false
        out.effects.append(.windowMode(false))
    }

    // MARK: Helpers

    private func flushPending(_ out: inout Output) {
        guard case let .pending(code, flags, _, _) = sd else { return }
        sd = .idle
        timerToken += 1
        out.emits.append(.synth(code: code, down: true, flags: flags, isRepeat: false))
    }

    private func emitRemap(_ remap: Remap, _ e: KeyEvent, down: Bool, _ out: inout Output) {
        switch remap {
        case let .key(code, extra):
            let flags = e.flags.intersection(modifierMask).union(extra).union(virtualMods)
            out.emits.append(.synth(code: code, down: down, flags: flags, isRepeat: e.isRepeat))
        case let .modifier(flag):
            if down { virtualMods.insert(flag) } else { virtualMods.remove(flag) }
        }
    }

    private func isControlS(_ e: KeyEvent) -> Bool {
        e.code == Key.s && e.flags.intersection(modifierMask) == .maskControl
    }

    private func hasNoModifiers(_ e: KeyEvent) -> Bool {
        e.flags.intersection(modifierMask).isEmpty
    }

    private func partner(of code: UInt16) -> UInt16 { code == Key.s ? Key.d : Key.s }
}
