import AppKit
import Carbon
import ChronicleDesktopCore

final class ShortcutRecorderField: NSTextField {
    private(set) var shortcut: ShortcutSpec {
        didSet {
            stringValue = ShortcutParser.displayString(for: shortcut)
        }
    }

    private var previousFlags: NSEvent.ModifierFlags = []
    private var lastControlDownAt: Date?

    init(shortcut: ShortcutSpec) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        stringValue = ShortcutParser.displayString(for: shortcut)
        placeholderString = "Press shortcut"
        isEditable = false
        isSelectable = false
        focusRingType = .default
        bezelStyle = .roundedBezel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            stringValue = "Press keys..."
        }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        stringValue = ShortcutParser.displayString(for: shortcut)
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let spec = hotKeySpec(from: event) else {
            return
        }
        shortcut = .hotKey(spec)
    }

    override func flagsChanged(with event: NSEvent) {
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
            shortcut = .doubleControl
            self.lastControlDownAt = nil
        } else {
            lastControlDownAt = now
        }
    }

    private func hotKeySpec(from event: NSEvent) -> HotKeySpec? {
        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            return nil
        }

        let keyCode = UInt32(event.keyCode)
        guard keyCode != UInt32(kVK_Control),
              keyCode != UInt32(kVK_RightControl),
              keyCode != UInt32(kVK_Command),
              keyCode != UInt32(kVK_RightCommand),
              keyCode != UInt32(kVK_Option),
              keyCode != UInt32(kVK_RightOption),
              keyCode != UInt32(kVK_Shift),
              keyCode != UInt32(kVK_RightShift)
        else {
            return nil
        }

        return HotKeySpec(keyCode: keyCode, modifiers: modifiers)
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}
