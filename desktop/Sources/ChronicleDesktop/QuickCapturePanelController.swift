import AppKit
import SwiftUI
import ChronicleDesktopCore

final class QuickCapturePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, shouldUsePanelCancelFallback else {
            super.keyDown(with: event)
            return
        }
        onCancel?()
    }

    private var shouldUsePanelCancelFallback: Bool {
        guard let responder = firstResponder else { return true }
        if let textView = responder as? NSTextView {
            return !textView.isEditable && !textView.hasMarkedText()
        }
        return true
    }
}

@MainActor
final class QuickCapturePanelController: NSWindowController, NSWindowDelegate {
    private let clients: CaptureClients
    private let onSubmit: (String, Date?, Bool) -> QuickCaptureSaveResult
    private let focusRestorer = QuickCaptureFocusRestorer()
    private var hostingView: NSHostingView<PanelContentView>!
    private var isExplicitlyHiding = false

    init(
        clients: CaptureClients,
        onSubmit: @escaping (String, Date?, Bool) -> QuickCaptureSaveResult
    ) {
        self.clients = clients
        self.onSubmit = onSubmit

        let panel = QuickCapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.level = .floating
        // Appear on the active Space (and over a fullscreen app), so the global
        // hotkey opens the panel where the user is, not on a stale Space.
        panel.collectionBehavior.insert(.moveToActiveSpace)
        panel.collectionBehavior.insert(.fullScreenAuxiliary)

        super.init(window: panel)
        panel.delegate = self

        let root = PanelContentView(
            clients: clients,
            onSubmit: { [weak self] text, remindAt, keepVisible in
                self?.onSubmit(text, remindAt, keepVisible)
                    ?? .failed(L("We couldn't save this Capture. Try again."))
            },
            onClose: { [weak self] in self?.hide(restoringPreviousFocus: true) },
            onHeightChange: { [weak self] height in self?.resize(to: height) },
            onCancelHandlerChange: { [weak panel] handler in panel?.onCancel = handler },
        )
        hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        focusRestorer.rememberFrontmostApplication()
        // Open on the display the cursor is on, not wherever the panel last showed
        // (window.center() read window.screen, so it stuck to the previous screen).
        // x: centered on that screen. y: TOP edge anchored above center, so the
        // panel opens in the same place and the results area grows downward.
        if let screen = ScreenPlacement.active() ?? window.screen {
            var frame = window.frame
            let vf = screen.visibleFrame
            frame.origin.x = PanelLayout.centeredOrigin(in: vf, size: frame.size).x
            frame.origin.y = PanelLayout.originY(visibleFrame: vf, height: frame.size.height)
            window.setFrame(frame, display: false)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .chroniclePanelShown, object: nil)
    }

    private func hide(restoringPreviousFocus: Bool) {
        guard let window, window.isVisible else { return }
        isExplicitlyHiding = true
        window.orderOut(nil)
        if restoringPreviousFocus {
            focusRestorer.restore()
        } else {
            focusRestorer.discard()
        }
        isExplicitlyHiding = false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isExplicitlyHiding else { return }
        hide(restoringPreviousFocus: false)
    }

    private func resize(to height: CGFloat) {
        guard let window, height > 0 else { return }
        var frame = window.frame
        frame.size.height = height
        frame.size.width = 540
        // Re-anchor to the canonical top edge rather than the current maxY, so the
        // panel grows downward from the same line it opened at — same source of
        // truth as show().
        if let screen = window.screen ?? NSScreen.main {
            frame.origin.y = PanelLayout.originY(visibleFrame: screen.visibleFrame, height: height)
        } else {
            frame.origin.y = frame.maxY - height
        }
        window.setFrame(frame, display: true, animate: false)
    }
}

@MainActor
private final class QuickCaptureFocusRestorer {
    private var state = QuickPanelFocusState()
    private let currentProcessIdentifier: pid_t

    init(currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.currentProcessIdentifier = currentProcessIdentifier
    }

    func rememberFrontmostApplication() {
        state.remember(
            frontmostApplicationProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            currentApplicationProcessIdentifier: currentProcessIdentifier,
        )
    }

    func restore() {
        guard let processIdentifier = state.consumeForRestore() else { return }
        NSRunningApplication(processIdentifier: processIdentifier)?.activate(options: [])
    }

    func discard() {
        state.discard()
    }
}
