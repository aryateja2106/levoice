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

    /// Starts the Hyperkey tap if settings.enabled. No-op otherwise.
    /// - Returns: `false` if Accessibility permission is missing or the tap could not be created.
    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        let shouldRun = settings.enabled
        stateLock.unlock()
        guard shouldRun else { return true }

        if eventTap != nil { return true }

        let thread = HyperkeyMonitorThread()
        thread.name = "LeVoice Hyperkey Monitor"
        thread.start()
        thread.waitUntilReady()

        let request = HyperkeyTapInstallRequest()
        perform(#selector(installEventTap(_:)), on: thread, with: request, waitUntilDone: true)

        guard request.succeeded else {
            perform(#selector(uninstallEventTapAndStopRunLoop), on: thread, with: nil, waitUntilDone: true)
            debugLogger?(.hotkey, "Hyperkey failed to start — Accessibility permission missing.")
            return false
        }

        tapThread = thread
        debugLogger?(.hotkey, "Hyperkey tap started (remap=\(settings.remappedKeyCode), quickPress=\(settings.quickPressKeyCode), includeShift=\(settings.includeShift)).")
        return true
    }

    func stop() {
        guard let thread = tapThread else { return }
        perform(#selector(uninstallEventTapAndStopRunLoop), on: thread, with: nil, waitUntilDone: true)
        tapThread = nil
        stateLock.lock()
        state = State()
        stateLock.unlock()
        debugLogger?(.hotkey, "Hyperkey tap stopped.")
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

        let remappedCode = current.remappedKeyCode
        let eventCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isRemappedKey = (eventCode == remappedCode)

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
            local.keyPressedWhileHeld = true
            stateLock.lock()
            state = local
            stateLock.unlock()

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
