// Tests for the pure Engine and Geometry. Build & run with `make test`.
// Plain asserts, no XCTest, so it works with just the Command Line Tools.

import CoreGraphics

var failures = 0
var passed = 0

func check<T: Equatable>(_ actual: T, _ expected: T, _ name: String, line: Int = #line) {
    if actual == expected { passed += 1; return }
    failures += 1
    print("FAIL [line \(line)] \(name)\n  expected: \(expected)\n  actual:   \(actual)")
}

// MARK: Event helpers

var clock = 100.0
func advance(_ seconds: Double) { clock += seconds }

func down(_ code: UInt16, _ flags: CGEventFlags = [], repeat isRepeat: Bool = false) -> KeyEvent {
    KeyEvent(kind: .keyDown, code: code, flags: flags, isRepeat: isRepeat, time: clock)
}
func up(_ code: UInt16, _ flags: CGEventFlags = []) -> KeyEvent {
    KeyEvent(kind: .keyUp, code: code, flags: flags, time: clock)
}
let rightControlDown = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | rightControlDownBit)
func capsPress() -> KeyEvent { KeyEvent(kind: .flagsChanged, code: Key.rightControl, flags: rightControlDown, time: clock) }
func capsRelease() -> KeyEvent { KeyEvent(kind: .flagsChanged, code: Key.rightControl, flags: [], time: clock) }

let pass = Emit.original(flags: [])
func synth(_ code: UInt16, _ down: Bool, _ flags: CGEventFlags = [], repeat r: Bool = false) -> Emit {
    .synth(code: code, down: down, flags: flags, isRepeat: r)
}
let escapeTap = [synth(Key.escape, true), synth(Key.escape, false)]

/// Press s+d together and return the engine in (S)uper (D)uper mode.
func superDuper(_ e: Engine) {
    _ = e.handle(down(Key.s))
    advance(0.01)
    _ = e.handle(down(Key.d))
}

func test(_ name: String, _ body: (Engine) -> Void) {
    clock = 100
    body(Engine())
}

// MARK: - Caps lock → control / escape

test("caps tap sends escape after the control release") { e in
    check(e.handle(capsPress()).emits, [.original(flags: rightControlDown)], "press passes through")
    advance(0.08)
    check(e.handle(capsRelease()).emits, [pass] + escapeTap, "release then escape")
}

test("caps held past threshold is just control") { e in
    _ = e.handle(capsPress())
    advance(0.2)
    check(e.handle(capsRelease()).emits, [pass], "no escape")
}

test("caps + key is control+key, no escape") { e in
    _ = e.handle(capsPress())
    advance(0.02)
    check(e.handle(down(Key.c, .maskControl)).emits, [.original(flags: .maskControl)], "ctrl+c passes")
    _ = e.handle(up(Key.c, .maskControl))
    advance(0.02)
    check(e.handle(capsRelease()).emits, [pass], "no escape")
}

test("physical left control tap does not send escape") { e in
    let leftDown = KeyEvent(kind: .flagsChanged, code: Key.leftControl, flags: .maskControl, time: clock)
    _ = e.handle(leftDown)
    advance(0.05)
    let leftUp = KeyEvent(kind: .flagsChanged, code: Key.leftControl, flags: [], time: clock)
    check(e.handle(leftUp).emits, [pass], "no escape")
}

test("raw caps lock event asks to re-apply the mapping") { e in
    let caps = KeyEvent(kind: .flagsChanged, code: Key.capsLock, flags: .maskAlphaShift, time: clock)
    let out = e.handle(caps)
    check(out.effects, [.reapplyCapsMapping], "effect")
    check(out.emits, [.original(flags: .maskAlphaShift)], "passes through")
}

// MARK: - (S)uper (D)uper mode

test("s+d then hjkl gives arrows") { e in
    check(e.handle(down(Key.s)).emits, [], "s held back")
    advance(0.02)
    let dOut = e.handle(down(Key.d))
    check(dOut.emits, [], "d swallowed, mode on")
    for (key, arrow) in [(Key.h, Key.left), (Key.j, Key.down), (Key.k, Key.up), (Key.l, Key.right)] {
        check(e.handle(down(key)).emits, [synth(arrow, true, arrowFlags)], "arrow down \(arrow)")
        check(e.handle(up(key)).emits, [synth(arrow, false, arrowFlags)], "arrow up \(arrow)")
    }
    check(e.handle(up(Key.d)).emits, [], "d up swallowed, mode off")
    check(e.handle(up(Key.s)).emits, [], "s up swallowed")
    check(e.handle(down(Key.h)).emits, [pass], "h is h again")
}

test("d+s order also works") { e in
    _ = e.handle(down(Key.d))
    advance(0.03)
    check(e.handle(down(Key.s)).emits, [], "mode on")
    check(e.handle(down(Key.j)).emits, [synth(Key.down, true, arrowFlags)], "arrow")
}

test("s alone is released by the timer") { e in
    let out = e.handle(down(Key.s))
    check(out.emits, [], "held back")
    guard let timer = out.timer else { return check(false, true, "timer requested") }
    check(timer.delay, Tuning.simultaneousThreshold, "timer delay")
    check(e.timerFired(token: timer.token).emits, [synth(Key.s, true)], "s emitted on timeout")
    check(e.handle(up(Key.s)).emits, [pass], "s up passes")
    check(e.timerFired(token: timer.token).emits, [], "stale timer is a no-op")
}

test("s then another key flushes s first, in order") { e in
    _ = e.handle(down(Key.s))
    advance(0.01)
    check(e.handle(down(Key.x)).emits, [synth(Key.s, true), pass], "s then x")
}

test("s quickly released emits down then up") { e in
    _ = e.handle(down(Key.s))
    advance(0.02)
    check(e.handle(up(Key.s)).emits, [synth(Key.s, true), pass], "s down, s up")
}

test("s then d too slowly is just typing") { e in
    let first = e.handle(down(Key.s))
    advance(0.06)
    let out = e.handle(down(Key.d))
    check(out.emits, [synth(Key.s, true)], "s flushed, d now held back")
    check(out.timer != nil && out.timer != first.timer, true, "new timer for d")
}

test("typing 'ss' quickly") { e in
    _ = e.handle(down(Key.s))
    _ = e.handle(up(Key.s))
    advance(0.01)
    check(e.handle(down(Key.s)).timer != nil, true, "second s held back too")
}

test("rollover 'as' keeps the a key-up in place") { e in
    check(e.handle(down(Key.a)).emits, [pass], "a")
    check(e.handle(down(Key.s)).emits, [], "s held")
    check(e.handle(up(Key.a)).emits, [pass], "a up passes while s held")
    check(e.handle(up(Key.s)).emits, [synth(Key.s, true), pass], "s flushed")
}

test("shift+s does not start the chord") { e in
    check(e.handle(down(Key.s, .maskShift)).emits, [.original(flags: .maskShift)], "S passes")
}

test("a = option: a+j is option+down (page down)") { e in
    superDuper(e)
    check(e.handle(down(Key.a)).emits, [], "a swallowed")
    check(e.handle(down(Key.j)).emits, [synth(Key.down, true, arrowFlags.union(.maskAlternate))], "opt+down")
    check(e.handle(up(Key.j)).emits, [synth(Key.down, false, arrowFlags.union(.maskAlternate))], "opt+down up")
    check(e.handle(up(Key.a)).emits, [], "a up swallowed")
    check(e.handle(down(Key.j)).emits, [synth(Key.down, true, arrowFlags)], "option released")
}

test("a+h is option+left (previous word)") { e in
    superDuper(e)
    _ = e.handle(down(Key.a))
    check(e.handle(down(Key.h)).emits, [synth(Key.left, true, arrowFlags.union(.maskAlternate))], "opt+left")
}

test("space = shift for selection") { e in
    superDuper(e)
    _ = e.handle(down(Key.space))
    check(e.handle(down(Key.l)).emits, [synth(Key.right, true, arrowFlags.union(.maskShift))], "shift+right")
}

test("f = command applies to unmapped keys too") { e in
    superDuper(e)
    _ = e.handle(down(Key.f))
    check(e.handle(down(Key.c)).emits, [.original(flags: .maskCommand)], "cmd+c")
}

test("u/i/o/p are tab navigation") { e in
    superDuper(e)
    check(e.handle(down(Key.u)).emits, [synth(Key.one, true, .maskCommand)], "first tab")
    check(e.handle(down(Key.i)).emits, [synth(Key.openBracket, true, [.maskCommand, .maskShift])], "prev tab")
    check(e.handle(down(Key.o)).emits, [synth(Key.closeBracket, true, [.maskCommand, .maskShift])], "next tab")
    check(e.handle(down(Key.p)).emits, [synth(Key.nine, true, .maskCommand)], "last tab")
}

test("physical modifiers pass through to arrows") { e in
    superDuper(e)
    check(e.handle(down(Key.h, .maskShift)).emits, [synth(Key.left, true, arrowFlags.union(.maskShift))], "shift+left")
}

test("arrow keeps repeating after the chord is released, until h is up") { e in
    superDuper(e)
    _ = e.handle(down(Key.h))
    _ = e.handle(up(Key.d)) // mode off
    check(e.handle(down(Key.h, repeat: true)).emits, [synth(Key.left, true, arrowFlags, repeat: true)], "repeat")
    check(e.handle(up(Key.h)).emits, [synth(Key.left, false, arrowFlags)], "released")
    check(e.handle(down(Key.h)).emits, [pass], "plain h now")
}

test("holding the chord swallows s/d autorepeat") { e in
    superDuper(e)
    check(e.handle(down(Key.s, repeat: true)).emits, [], "s repeat")
    check(e.handle(down(Key.d, repeat: true)).emits, [], "d repeat")
}

test("unmapped key in mode passes through") { e in
    superDuper(e)
    check(e.handle(down(Key.x)).emits, [pass], "x")
}

test("reset releases held synthetic keys") { e in
    superDuper(e)
    _ = e.handle(down(Key.j))
    check(e.reset().emits, [synth(Key.down, false, arrowFlags)], "down arrow released")
    check(e.handle(down(Key.j)).emits, [pass], "fresh state")
}

test("reset flushes a held-back s") { e in
    _ = e.handle(down(Key.s))
    check(e.reset().emits, [synth(Key.s, true)], "s emitted")
}

// MARK: - Window Layout mode

test("ctrl+s then h moves window left") { e in
    let enter = e.handle(down(Key.s, .maskControl))
    check(enter.emits, [], "ctrl+s swallowed")
    check(enter.effects, [.windowMode(true)], "mode on")
    check(e.handle(up(Key.s, .maskControl)).emits, [], "s up swallowed")
    let act = e.handle(down(Key.h))
    check(act.emits, [], "h swallowed")
    check(act.effects, [.windowMode(false), .window(.left)], "exit + move")
    check(e.handle(up(Key.h)).emits, [], "h up swallowed")
    check(e.handle(down(Key.h)).emits, [pass], "h normal again")
}

test("every window binding") { e in
    let cases: [(UInt16, CGEventFlags, WindowAction)] = [
        (Key.returnKey, [], .maximize), (Key.space, [], .center),
        (Key.h, [], .left), (Key.j, [], .down), (Key.k, [], .up), (Key.l, [], .right),
        (Key.h, .maskShift, .left40), (Key.l, .maskShift, .right60),
        (Key.i, [], .upLeft), (Key.o, [], .upRight), (Key.comma, [], .downLeft), (Key.period, [], .downRight),
        (Key.n, [], .nextScreen), (Key.right, arrowFlags, .screenEast), (Key.left, arrowFlags, .screenWest),
    ]
    for (code, flags, action) in cases {
        _ = e.handle(down(Key.s, .maskControl)); _ = e.handle(up(Key.s))
        check(e.handle(down(code, flags)).effects, [.windowMode(false), .window(action)], "\(action)")
        _ = e.handle(up(code))
    }
}

test("still holding caps (control) in window mode is fine") { e in
    _ = e.handle(down(Key.s, .maskControl))
    check(e.handle(down(Key.l, .maskControl)).effects, [.windowMode(false), .window(.right)], "ctrl ignored")
}

test("ctrl+s twice cancels") { e in
    _ = e.handle(down(Key.s, .maskControl)); _ = e.handle(up(Key.s, .maskControl))
    check(e.handle(down(Key.s, .maskControl)).effects, [.windowMode(false)], "cancelled")
    check(e.handle(up(Key.s, .maskControl)).emits, [], "s up swallowed")
}

test("escape cancels window mode") { e in
    _ = e.handle(down(Key.s, .maskControl)); _ = e.handle(up(Key.s))
    check(e.handle(down(Key.escape)).effects, [.windowMode(false)], "cancelled")
}

test("caps tap cancels window mode without sending escape") { e in
    _ = e.handle(down(Key.s, .maskControl)); _ = e.handle(up(Key.s))
    _ = e.handle(capsPress())
    advance(0.05)
    let out = e.handle(capsRelease())
    check(out.emits, [pass], "no escape")
    check(out.effects, [.windowMode(false)], "cancelled")
}

test("unmapped key cancels window mode and is swallowed") { e in
    _ = e.handle(down(Key.s, .maskControl)); _ = e.handle(up(Key.s))
    let out = e.handle(down(Key.x))
    check(out.emits, [], "swallowed")
    check(out.effects, [.windowMode(false)], "cancelled")
    check(e.handle(up(Key.x)).emits, [], "x up swallowed")
}

test("cmd+h in window mode does not move the window") { e in
    _ = e.handle(down(Key.s, .maskControl)); _ = e.handle(up(Key.s))
    check(e.handle(down(Key.h, .maskCommand)).effects, [.windowMode(false)], "no action")
}

test("ctrl+shift+s is not the trigger") { e in
    let flags: CGEventFlags = [.maskControl, .maskShift]
    check(e.handle(down(Key.s, flags)).effects, [], "no mode")
}

test("held-back d is flushed before entering window mode") { e in
    _ = e.handle(down(Key.d))
    let out = e.handle(down(Key.s, .maskControl))
    check(out.emits, [synth(Key.d, true)], "d emitted")
    check(out.effects, [.windowMode(true)], "mode on")
}

test("a stale swallowed key-up does not eat a later normal key-up") { e in
    _ = e.handle(down(Key.s, .maskControl))
    _ = e.handle(down(Key.h)) // h up never arrives (e.g., tap disabled)
    check(e.handle(down(Key.h)).emits, [pass], "fresh h passes")
    check(e.handle(up(Key.h)).emits, [pass], "its key-up passes too")
}

// MARK: - Geometry

let screen = CGRect(x: 0, y: 25, width: 1440, height: 875) // below a 25pt menu bar
let win = CGRect(x: 100, y: 100, width: 600, height: 400)
func target(_ a: WindowAction, _ w: CGRect = win, _ screens: [CGRect] = [screen]) -> CGRect? {
    Geometry.target(for: a, window: w, screens: screens)
}

check(target(.left), CGRect(x: 0, y: 25, width: 720, height: 875), "left half")
check(target(.right), CGRect(x: 720, y: 25, width: 720, height: 875), "right half")
check(target(.up), CGRect(x: 0, y: 25, width: 1440, height: 438), "top half (rounded)")
check(target(.down), CGRect(x: 0, y: 463, width: 1440, height: 437), "bottom half (rounded)")
check(target(.upLeft), CGRect(x: 0, y: 25, width: 720, height: 438), "upper-left")
check(target(.upRight), CGRect(x: 720, y: 25, width: 720, height: 438), "upper-right")
check(target(.downLeft), CGRect(x: 0, y: 463, width: 720, height: 437), "lower-left")
check(target(.downRight), CGRect(x: 720, y: 463, width: 720, height: 437), "lower-right")
check(target(.center), CGRect(x: 288, y: 25, width: 864, height: 875), "center 60% full height")
check(target(.left40), CGRect(x: 0, y: 25, width: 576, height: 875), "left 40%")
check(target(.right60), CGRect(x: 576, y: 25, width: 864, height: 875), "right 60%")
check(target(.maximize), screen, "maximize")
check(target(.nextScreen), nil, "single screen: nowhere to go")
check(target(.screenEast), nil, "single screen: nothing east")

// Two displays: a 2560x1415 external to the right of the laptop, top-aligned.
let external = CGRect(x: 1440, y: 0, width: 2560, height: 1415)
let two = [screen, external]
check(target(.screenEast, win, two),
      CGRect(x: 1618, y: 121, width: 1066, height: 647), "east keeps proportional frame")
check(target(.screenWest, win, two), nil, "nothing west of the laptop")
check(target(.nextScreen, win, two), target(.screenEast, win, two), "next = the other screen")
let onExternal = CGRect(x: 2000, y: 200, width: 800, height: 600)
check(target(.screenWest, onExternal, two)?.minX, 315, "west lands on laptop")
check(target(.nextScreen, onExternal, two)?.minX, 315, "next wraps around")
check(target(.left, onExternal, two), CGRect(x: 1440, y: 0, width: 1280, height: 1415), "acts on its own screen")

// A window straddling both displays belongs to the one it overlaps most.
check(Geometry.screenIndex(for: CGRect(x: 1300, y: 100, width: 600, height: 400), screens: two), 1, "mostly external")
check(Geometry.screenIndex(for: CGRect(x: 1000, y: 100, width: 600, height: 400), screens: two), 0, "mostly laptop")
// Off-screen windows pick the nearest display.
check(Geometry.screenIndex(for: CGRect(x: 5000, y: 100, width: 100, height: 100), screens: two), 1, "nearest")
// Oversized windows are clamped to fit when moving.
let huge = CGRect(x: 1440, y: 0, width: 2560, height: 1415)
check(target(.screenWest, huge, two), screen, "full-screen window fits the smaller display")

// Display arranged to the left (negative x) and above.
let leftOf = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
check(target(.screenWest, win, [screen, leftOf])?.minX, -1787, "west to a display at negative x")
check(target(.screenEast, CGRect(x: -1000, y: 0, width: 500, height: 500), [screen, leftOf])?.minX, 690, "east back")

print(failures == 0 ? "OK: \(passed) checks passed" : "\(failures) FAILED, \(passed) passed")
exit(failures == 0 ? 0 : 1)
