import Cocoa
import CoreGraphics
import IOKit.hidsystem

/// In-app Hyperkey: remaps a physical key (default Caps Lock) so that while held it
/// injects ⌘⌥⌃(⇧) into subsequent keystrokes. A quick tap fires a user-configured
/// secondary key (default Escape) instead of the hyper chord. Requires Accessibility
/// permission — the same permission `HotkeyMonitor` already needs.
///
/// Architecture note: runs as a separate CGEvent tap in `.defaultTap` mode so it can
/// swallow the Caps Lock toggle and insert modifier flags. Tagged events carry a
/// sentinel in the `eventSourceUserData` field so `HotkeyMonitor` can skip them and
/// avoid recursion with its ChordEngine.
final class HyperkeyManager: NSObject {
    /// Sentinel value HotkeyMonitor checks to skip events synthesised by this manager.
    static let eventSourceUserDataSentinel: Int64 = 0x1EC0DE

    private var settings: HyperkeySettings
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: HyperkeyMonitorThread?

    fileprivate var state = State()
    private let stateLock = NSLock()

    var debugLogger: ((DebugLogCategory, String) -> Void)?

    init(settings: HyperkeySettings = .default) {
        self.settings = settings
    }

    // MARK: - Public API

    /// Starts the Hyperkey tap if `settings.enabled`. When the trigger is Caps
    /// Lock (the default) this also applies a system-wide HID-level remap so
    /// Caps Lock produces F18 keyDown/keyUp events we can actually state-machine.
    /// - Returns: `false` if Input Monitoring permission is missing or the tap
    ///   could not be created.
    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        let shouldRun = settings.enabled
        let needsHIDRemap = shouldRun && settings.remappedKeyCode == capsLockKeyCode
        stateLock.unlock()
        guard shouldRun else { return true }

        if eventTap != nil { return true }

        // Apply HID remap BEFORE installing the tap so the first F18 event hits
        // our tap with no race window.
        if needsHIDRemap {
            let applied = HyperkeyHIDRemapper.enable()
            debugLogger?(.hotkey, applied
                ? "HID remap applied (Caps Lock → F18, system-wide)."
                : "HID remap FAILED — Hyperkey may be unreliable until macOS restart.")
        }

        let thread = HyperkeyMonitorThread()
        thread.name = "LeVoice Hyperkey Monitor"
        thread.start()
        thread.waitUntilReady()

        let request = HyperkeyTapInstallRequest()
        perform(#selector(installEventTap(_:)), on: thread, with: request, waitUntilDone: true)

        guard request.succeeded else {
            perform(#selector(uninstallEventTapAndStopRunLoop), on: thread, with: nil, waitUntilDone: true)
            if needsHIDRemap { HyperkeyHIDRemapper.disable() }
            debugLogger?(.hotkey, "Hyperkey failed to start — Input Monitoring permission missing.")
            return false
        }

        tapThread = thread
        debugLogger?(.hotkey, "Hyperkey tap started (listeningKey=\(listeningKeyCode), quickPress=\(settings.quickPressKeyCode), includeShift=\(settings.includeShift)).")
        return true
    }

    func stop() {
        if let thread = tapThread {
            perform(#selector(uninstallEventTapAndStopRunLoop), on: thread, with: nil, waitUntilDone: true)
        }
        tapThread = nil
        stateLock.lock()
        state = State()
        stateLock.unlock()
        // Always clear the HID remap on stop, even if the tap wasn't actually
        // running — guarantees Caps Lock returns to default whenever Hyperkey is off.
        HyperkeyHIDRemapper.disable()
        debugLogger?(.hotkey, "Hyperkey tap stopped, HID remap cleared.")
    }

    /// The virtual keyCode our tap listens for, given the current settings.
    /// When Caps Lock is the trigger, `hidutil` has already rewritten the
    /// physical Caps key to F18 at the HID layer, so we listen for F18.
    var listeningKeyCode: UInt16 {
        if settings.remappedKeyCode == capsLockKeyCode {
            return HyperkeyHIDRemapper.f18VirtualKeyCode
        }
        return settings.remappedKeyCode
    }

    /// Carbon `kVK_ANSI_CapsLock`.
    private let capsLockKeyCode: UInt16 = 57

    /// Keys that shouldn't count as "user pressed another key while Hyperkey
    /// was held" when detecting quick tap. Pressing Shift alone during a hold
    /// shouldn't cancel the quick-tap synthesis — the user didn't actually
    /// invoke a hyper-modified shortcut.
    ///
    /// Internal (not private) so tests can cover the predicate directly without
    /// synthesising a full CGEvent stream.
    func isModifierKeyCode(_ code: UInt16) -> Bool {
        // 54 rcmd, 55 lcmd, 56 lshift, 58 lopt, 59 lctrl, 60 rshift, 61 ropt,
        // 62 rctrl, 63 fn, 57 caps (already swallowed but belt-and-braces).
        switch code {
        case 54, 55, 56, 57, 58, 59, 60, 61, 62, 63: return true
        default: return false
        }
    }

    /// Applies new settings. Starts/stops the tap as needed.
    func updateSettings(_ newSettings: HyperkeySettings) {
        stateLock.lock()
        let wasEnabled = settings.enabled
        settings = newSettings
        stateLock.unlock()

        switch (wasEnabled, newSettings.enabled) {
        case (false, true):
            start()
        case (true, false):
            stop()
        default:
            break
        }
    }

    // MARK: - Event handling (called from the tap thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Skip events we generated ourselves to avoid feedback loops.
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventSourceUserDataSentinel {
            return Unmanaged.passUnretained(event)
        }

        stateLock.lock()
        let current = settings
        var local = state
        stateLock.unlock()

        // After HID remap (Caps → F18), we listen for F18 keyDown/keyUp pairs.
        // For non-Caps trigger keys (F13-F16) we listen for those keyCodes
        // directly. Fall-through flagsChanged path remains for safety.
        let triggerCode = listeningKeyCode
        let eventCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isRemappedKey = (eventCode == triggerCode)

        // ── Trigger key: press or release ──────────────────────────────────────
        if isRemappedKey {
            let isPressed: Bool
            switch type {
            case .flagsChanged:
                // Caps Lock generates flagsChanged with maskAlphaShift toggling.
                isPressed = !local.isHeld
            case .keyDown:
                isPressed = true
            case .keyUp:
                isPressed = false
            default:
                return Unmanaged.passUnretained(event)
            }

            if isPressed {
                local.isHeld = true
                local.heldAt = Date()
                local.keyPressedWhileHeld = false
            } else {
                let duration = Date().timeIntervalSince(local.heldAt ?? Date())
                local.isHeld = false
                if duration < HyperkeySettings.quickPressThresholdSeconds && !local.keyPressedWhileHeld {
                    synthesizeQuickPress(code: current.quickPressKeyCode)
                }
                local.heldAt = nil
                local.keyPressedWhileHeld = false
            }

            stateLock.lock()
            state = local
            stateLock.unlock()
            // Swallow the trigger event so the system never processes caps-lock toggle
            // (or a stray F13 keypress leaking into apps).
            return nil
        }

        // ── While held: inject hyper modifiers into other keystrokes ───────────
        if local.isHeld && (type == .keyDown || type == .keyUp) {
            // Only count non-modifier keys as "a key was pressed during the hold".
            // Pressing Shift alone during a hold (to prepare for Hyper+Shift+X)
            // shouldn't cancel the quick-tap path if the user then releases
            // without actually firing a non-modifier key.
            if !isModifierKeyCode(eventCode) {
                local.keyPressedWhileHeld = true
                stateLock.lock()
                state = local
                stateLock.unlock()
            }

            var flags = event.flags
            flags.insert(.maskCommand)
            flags.insert(.maskAlternate)
            flags.insert(.maskControl)
            if current.includeShift {
                flags.insert(.maskShift)
            }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventSourceUserDataSentinel)
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Quick press synthesis

    private func synthesizeQuickPress(code: UInt16) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return }
        down.setIntegerValueField(.eventSourceUserData, value: Self.eventSourceUserDataSentinel)
        up.setIntegerValueField(.eventSourceUserData, value: Self.eventSourceUserDataSentinel)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Tap lifecycle (runs on tap thread)

    @objc private func installEventTap(_ request: HyperkeyTapInstallRequest) {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hyperkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            request.succeeded = false
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        request.succeeded = true
    }

    @objc private func uninstallEventTapAndStopRunLoop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    fileprivate struct State {
        var isHeld: Bool = false
        var heldAt: Date?
        var keyPressedWhileHeld: Bool = false
    }
}

private final class HyperkeyMonitorThread: Thread {
    private let readySemaphore = DispatchSemaphore(value: 0)
    private let keepAlivePort = Port()

    override func main() {
        autoreleasepool {
            RunLoop.current.add(keepAlivePort, forMode: .default)
            readySemaphore.signal()
            CFRunLoopRun()
        }
    }

    func waitUntilReady() {
        readySemaphore.wait()
    }
}

private final class HyperkeyTapInstallRequest: NSObject {
    var succeeded = false
}

// MARK: - C callback

private func hyperkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    // Re-enable the tap if the system disabled it (timeout or user input).
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let manager = Unmanaged<HyperkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
        manager.debugLogger?(.hotkey, "Hyperkey tap re-enabled after system disabled it.")
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<HyperkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handle(type: type, event: event)
}
