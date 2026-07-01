import AppKit
import Carbon
import ChronicleDesktopCore
import Foundation

final class HotKeyController: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var previousFlags: NSEvent.ModifierFlags = []
    private var detector = DoubleTapDetector(window: 0.35)
    private let handler: @MainActor @Sendable () -> Void

    // The "real" modifiers a Control tap must not be combined with. Fn/CapsLock
    // aren't in here — they never form an intentional chord with the gesture —
    // but a change in any of them still invalidates the pair (see handleEvent).
    private static let realModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    init(spec: ShortcutSpec, handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
        install(spec: spec)
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    private func install(spec: ShortcutSpec) {
        switch spec {
        case .doubleControl:
            installDoubleControlMonitor()
        case let .hotKey(hotKey):
            installCarbonHotKey(spec: hotKey)
        }
    }

    private func installDoubleControlMonitor() {
        // keyDown joins flagsChanged so any ordinary keystroke between the two
        // Control taps can invalidate the gesture (it must be a clean repeat).
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleEvent(event)
            return event
        }
    }

    private func handleEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            // A plain key pressed between the two Control taps breaks the pair.
            detector.reset()
        case .flagsChanged:
            handleFlagsChanged(event)
        default:
            break
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let previous = previousFlags
        previousFlags = flags

        // A non-Control modifier (Shift/Option/Command/Fn/CapsLock) changed between
        // taps → not a clean single-key repeat, so drop the pending tap.
        if flags.subtracting(.control) != previous.subtracting(.control) {
            detector.reset()
            return
        }

        // Only the Control press edge counts (ignore its release and no-ops).
        guard flags.contains(.control), !previous.contains(.control) else {
            return
        }

        // Control must be pressed ALONE — if another real modifier is held at the
        // same moment (Ctrl+Shift and friends), it's a chord, not the gesture.
        guard flags.intersection(Self.realModifiers) == .control else {
            detector.reset()
            return
        }

        if detector.register(at: ProcessInfo.processInfo.systemUptime) {
            DispatchQueue.main.async {
                Task { @MainActor in
                    self.handler()
                }
            }
        }
    }

    private func installCarbonHotKey(spec: HotKeySpec) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else {
                    return noErr
                }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID,
                )
                if hotKeyID.id == 1 {
                    let controller = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
                    DispatchQueue.main.async {
                        Task { @MainActor in
                            controller.handler()
                        }
                    }
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            nil,
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4348524e), id: 1)
        RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef,
        )
    }
}
