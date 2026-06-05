import AppKit

final class QuickCapturePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

final class QuickCapturePanelController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    private let textField = NSTextField()
    private let onSubmit: (String) -> Void

    init(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit

        let panel = QuickCapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 88),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.level = .floating

        super.init(window: panel)
        panel.delegate = self
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else {
            return
        }
        textField.stringValue = ""
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textField)
    }

    override func cancelOperation(_ sender: Any?) {
        window?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        window?.orderOut(nil)
    }

    private func buildContent() {
        guard let contentView = window?.contentView else {
            return
        }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView.layer?.cornerRadius = 18
        contentView.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        textField.placeholderString = "Capture a thought..."
        textField.font = .systemFont(ofSize: 16)
        textField.delegate = self
        textField.focusRingType = .none
        textField.wantsLayer = true
        textField.layer?.cornerRadius = 12

        let hint = NSTextField(labelWithString: "Press Return to save. Press Esc to cancel.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)

        stack.addArrangedSubview(textField)
        stack.addArrangedSubview(hint)
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textField.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let movement = notification.userInfo?["NSTextMovement"] as? Int,
              movement == NSReturnTextMovement
        else {
            return
        }
        let value = textField.stringValue
        window?.orderOut(nil)
        onSubmit(value)
    }
}
