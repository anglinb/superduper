// main.swift — wiring the pure Engine/Geometry to macOS.
//
// What this process touches, and nothing else:
//   • A keyboard event tap (CGEventTap) — needs the Accessibility permission.
//   • The focused window's position/size (AXUIElement) — same permission.
//   • The `UserKeyMapping` property of attached keyboards, to make caps lock
//     act as right control (same mechanism as `/usr/bin/hidutil`). Removed on exit.
//   • A small on-screen label while Window Layout mode is active.
// No network, no files, no subprocesses, no config parsing, no persistence.

import AppKit
import ApplicationServices
import IOKit.hid
import IOKit.hidsystem

/// Marks events we post, so our own tap ignores them.
let syntheticMarker: Int64 = 0x5355_5045_5244_5550 // "SUPERDUP"

let engine = Engine()
let capsRemap = CapsRemap()
let hud = HUD()
let windowQueue = DispatchQueue(label: "superduper.window")
var eventTap: CFMachPort?

let eventSource: CGEventSource? = {
    let src = CGEventSource(stateID: .privateState)
    src?.userData = syntheticMarker
    return src
}()

func log(_ message: String) {
    FileHandle.standardError.write(Data("superduper: \(message)\n".utf8))
}

// MARK: - Event tap

func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        apply(engine.reset(), original: nil)
        return Unmanaged.passUnretained(event)
    case .keyDown, .keyUp, .flagsChanged:
        break
    default:
        return Unmanaged.passUnretained(event)
    }

    if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker {
        return Unmanaged.passUnretained(event)
    }

    let kind: KeyEventKind = type == .keyDown ? .keyDown : type == .keyUp ? .keyUp : .flagsChanged
    let keyEvent = KeyEvent(
        kind: kind,
        code: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
        flags: event.flags,
        isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
        time: ProcessInfo.processInfo.systemUptime)

    return apply(engine.handle(keyEvent), original: event)
}

/// Carry out the engine's decision. Returns the event to pass on, or nil to drop it.
@discardableResult
func apply(_ out: Output, original: CGEvent?) -> Unmanaged<CGEvent>? {
    defer { out.effects.forEach(perform) }

    if let timer = out.timer {
        DispatchQueue.main.asyncAfter(deadline: .now() + timer.delay) {
            apply(engine.timerFired(token: timer.token), original: nil)
        }
    }

    // Common case: let the original through, possibly with extra modifier flags.
    if out.emits.count == 1, case let .original(flags) = out.emits[0], let event = original {
        if event.flags != flags { event.flags = flags }
        return Unmanaged.passUnretained(event)
    }

    // Otherwise drop the original and post everything in order, so a held-back
    // key and the key that released it can never arrive out of sequence.
    for emit in out.emits {
        switch emit {
        case let .original(flags):
            guard let copy = original?.copy() else { continue }
            copy.flags = flags
            copy.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            copy.post(tap: .cgSessionEventTap)
        case let .synth(code, down, flags, isRepeat):
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }
    return nil
}

func perform(_ effect: Effect) {
    switch effect {
    case let .windowMode(on): on ? hud.show() : hud.hide()
    case .reapplyCapsMapping: capsRemap.applyDebounced()
    case let .window(action):
        // Read AppKit state on the main thread...
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let screens = visibleScreenFrames()
        // ...but Accessibility calls are IPC to the target app and can stall if
        // it's busy; keep them off the main thread so typing never lags.
        windowQueue.async { moveFocusedWindow(action, pid: pid, screens: screens) }
    }
}

// MARK: - Window management (Accessibility API)

func visibleScreenFrames() -> [CGRect] {
    guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
    // Cocoa: origin bottom-left. Accessibility: origin top-left of primary display.
    return NSScreen.screens.map {
        let f = $0.visibleFrame
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }
}

func moveFocusedWindow(_ action: WindowAction, pid: pid_t, screens: [CGRect]) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)

    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
          let windowRef = value, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return }
    let window = windowRef as! AXUIElement

    guard let origin: CGPoint = axValue(window, kAXPositionAttribute, .cgPoint),
          let size: CGSize = axValue(window, kAXSizeAttribute, .cgSize),
          let target = Geometry.target(for: action, window: CGRect(origin: origin, size: size), screens: screens)
    else { return }

    // Some apps animate every frame change while "enhanced user interface"
    // (set by assistive tools) is on, which makes moves slow and jumpy.
    let enhancedUI = "AXEnhancedUserInterface" as CFString
    var enhanced: CFTypeRef?
    let wasEnhanced = AXUIElementCopyAttributeValue(app, enhancedUI, &enhanced) == .success
        && (enhanced as? Bool) == true
    if wasEnhanced { AXUIElementSetAttributeValue(app, enhancedUI, kCFBooleanFalse) }

    // Size → position → size: the first resize lets the window fit when moving
    // to a smaller display; the second applies the size the new display allows.
    setAXValue(window, kAXSizeAttribute, target.size, .cgSize)
    setAXValue(window, kAXPositionAttribute, target.origin, .cgPoint)
    setAXValue(window, kAXSizeAttribute, target.size, .cgSize)

    if wasEnhanced { AXUIElementSetAttributeValue(app, enhancedUI, kCFBooleanTrue) }
}

func axValue<T: BitwiseCopyable>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType) -> T? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
          let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { pointer.deallocate() }
    return AXValueGetValue(ref as! AXValue, type, pointer) ? pointer.pointee : nil
}

func setAXValue<T: BitwiseCopyable>(_ element: AXUIElement, _ attribute: String, _ value: T, _ type: AXValueType) {
    var copy = value
    guard let axValue = AXValueCreate(type, &copy) else { return }
    AXUIElementSetAttributeValue(element, attribute as CFString, axValue)
}

// MARK: - Caps lock → right control (HID UserKeyMapping)

/// Right control (not left) so the physical control key keeps its normal
/// behavior; only the remapped caps lock gets tap-for-escape.
final class CapsRemap {
    private let key = kIOHIDUserKeyUsageMapKey as CFString
    private let srcKey = kIOHIDKeyboardModifierMappingSrcKey
    private let dstKey = kIOHIDKeyboardModifierMappingDstKey
    private let capsLock: UInt64 = 0x7_0000_0039     // HID usage page 7, usage 0x39
    private let rightControl: UInt64 = 0x7_0000_00E4 // HID usage page 7, usage 0xE4
    private var lastApplied = 0.0

    func apply() { update(add: true) }
    func remove() { update(add: false) }

    /// Re-apply at most once a second (called when a raw caps lock is seen).
    func applyDebounced() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastApplied > 1 else { return }
        apply()
    }

    private func update(add: Bool) {
        lastApplied = ProcessInfo.processInfo.systemUptime
        // Use a fresh client every time. A long-lived client's service list goes
        // stale: once a keyboard disconnects and reconnects (Bluetooth sleep,
        // re-pairing), it no longer lists that keyboard, so the remap would
        // silently apply to 0 services until superduper restarted.
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return }
        var count = 0
        for service in services where IOHIDServiceClientConformsTo(
            service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0 {
            // Preserve any other mappings the user set (e.g., with hidutil).
            var mappings = (IOHIDServiceClientCopyProperty(service, key) as? [[String: Any]]) ?? []
            mappings.removeAll { ($0[srcKey] as? NSNumber)?.uint64Value == capsLock }
            if add { mappings.append([srcKey: capsLock, dstKey: rightControl]) }
            if IOHIDServiceClientSetProperty(service, key, mappings as CFArray) { count += 1 }
        }
        log("\(add ? "applied" : "removed") caps lock mapping on \(count) keyboard service(s)")
    }
}

// MARK: - Window Layout mode indicator

final class HUD {
    private lazy var panel: NSPanel = {
        let label = NSTextField(labelWithString: "Window Layout Mode")
        label.font = .monospacedSystemFont(ofSize: 20, weight: .medium)
        label.textColor = .white
        let hint = NSTextField(labelWithString: "hjkl  ⇧h ⇧l  io,.  ⏎ ␣  n ← →   esc cancels")
        hint.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hint.textColor = NSColor.white.withAlphaComponent(0.7)

        let stack = NSStackView(views: [label, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        stack.layer?.cornerRadius = 10

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: stack.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = stack
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }()

    func show() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame, size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 20, y: f.minY + 20))
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

// MARK: - Startup

func startEventTap() -> Bool {
    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: mask,
                                      callback: tapCallback, userInfo: nil) else { return false }
    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

/// Wait (without busy-looping) for the Accessibility permission, then start.
func startWhenTrusted() {
    if AXIsProcessTrusted(), startEventTap() {
        capsRemap.apply()
        log("running")
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { startWhenTrusted() }
}

func exitCleanly(_ sig: Int32) -> Never {
    capsRemap.remove()
    exit(0)
}

// macOS grants Accessibility to the "responsible" app. Started from a shell,
// that's the terminal, and approving the prompt would give *every* process run
// from that terminal control of the machine. Only run under launchd so the
// grant is scoped to this one binary.
if getppid() != 1 {
    log("""
        refusing to start outside launchd: the Accessibility prompt would be for \
        your terminal app, not superduper. Use `make install`, then manage it with \
        `launchctl kickstart -k gui/$(id -u)/local.superduper`.
        """)
    exit(1)
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { exitCleanly(sig) }
    source.resume()
    signalSources.append(source)
}

// Shows the system prompt pointing at System Settings if not yet allowed.
let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
    log("waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar
startWhenTrusted()
app.run()
