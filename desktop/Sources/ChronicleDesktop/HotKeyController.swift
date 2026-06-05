import AppKit
import Carbon
import ChronicleDesktopCore
import Foundation

final class HotKeyController: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var previousFlags: NSEvent.ModifierFlags = []
    private var lastControlDownAt: Date?
    private let handler: @MainActor @Sendable () -> Void

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
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let controlIsDown = flags.contains(.control)
        let controlWasDown = previousFlags.contains(.control)
        previousFlags = flags

        guard controlIsDown, !controlWasDown else {
            return
        }

        let now = Date()
        if let lastControlDownAt,
           now.timeIntervalSince(lastControlDownAt) <= 0.35
        {
            self.lastControlDownAt = nil
            DispatchQueue.main.async {
                Task { @MainActor in
                    self.handler()
                }
            }
        } else {
            lastControlDownAt = now
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
