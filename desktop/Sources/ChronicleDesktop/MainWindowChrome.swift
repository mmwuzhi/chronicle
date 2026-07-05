import AppKit
import SwiftUI

// Window chrome for the main window, extracted from MainView.swift: the
// persisted navigation model, the collapsible tab rail, the NSWindow
// controller with its titlebar controls, and the hover-tracking sidebar
// button. No capture state lives here.

@MainActor
final class MainWindowNavigation: ObservableObject {
    private static let modeKey = "ChronicleMainWindowMode"
    private static let tabsExpandedKey = "ChronicleMainWindowTabsExpanded"
    private let defaults: UserDefaults

    @Published var mode: MainView.Mode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }

    @Published var tabsExpanded: Bool {
        didSet { defaults.set(tabsExpanded, forKey: Self.tabsExpandedKey) }
    }

    @Published private var tabsButtonHovering = false
    @Published private var tabsRailHovering = false
    @Published private var tabsHoverGrace = false
    @Published private var tabsHoverSuppressed = false
    @Published private(set) var suppressTabsExpandedAnimation = false
    private var tabsHoverGraceTask: Task<Void, Never>?
    private var tabsAnimationSuppressionTask: Task<Void, Never>?

    var tabsPeeking: Bool {
        tabsHoverSuppressed == false && (tabsButtonHovering || tabsRailHovering || tabsHoverGrace)
    }

    var tabsRailPeeking: Bool {
        tabsHoverSuppressed == false && tabsRailHovering
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.modeKey),
           let savedMode = MainView.Mode(rawValue: raw) {
            mode = savedMode
        } else {
            mode = .browse
        }
        if defaults.object(forKey: Self.tabsExpandedKey) == nil {
            tabsExpanded = true
        } else {
            tabsExpanded = defaults.bool(forKey: Self.tabsExpandedKey)
        }
    }

    func setTabsButtonHovering(_ hovering: Bool) {
        if hovering == false, tabsHoverSuppressed {
            tabsHoverSuppressed = false
            tabsButtonHovering = false
            tabsHoverGraceTask?.cancel()
            tabsHoverGrace = false
            return
        }
        if hovering == false {
            tabsHoverSuppressed = false
        }
        setTabsHovering(hovering) { self.tabsButtonHovering = $0 }
    }

    func setTabsRailHovering(_ hovering: Bool) {
        setTabsHovering(hovering) { self.tabsRailHovering = $0 }
    }

    private func setTabsHovering(_ hovering: Bool, assign: @escaping (Bool) -> Void) {
        if hovering {
            tabsHoverGraceTask?.cancel()
            tabsHoverGrace = false
            assign(true)
        } else {
            assign(false)
            holdTabsOpenBriefly()
        }
    }

    private func holdTabsOpenBriefly() {
        guard tabsButtonHovering == false, tabsRailHovering == false else { return }
        tabsHoverGraceTask?.cancel()
        tabsHoverGrace = true
        tabsHoverGraceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard Task.isCancelled == false else { return }
            tabsHoverGrace = false
        }
    }

    func toggleTabsExpanded() {
        let shouldSuppressExpansionAnimation = tabsExpanded == false && tabsPeeking
        setTabsExpandedAnimationSuppressed(shouldSuppressExpansionAnimation)
        tabsExpanded.toggle()
        if tabsExpanded {
            tabsHoverSuppressed = false
        } else {
            tabsHoverGraceTask?.cancel()
            tabsHoverGrace = false
            tabsHoverSuppressed = true
        }
    }

    private func setTabsExpandedAnimationSuppressed(_ suppressed: Bool) {
        tabsAnimationSuppressionTask?.cancel()
        suppressTabsExpandedAnimation = suppressed
        guard suppressed else { return }
        tabsAnimationSuppressionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard Task.isCancelled == false else { return }
            suppressTabsExpandedAnimation = false
        }
    }
}

struct MainTabRail: View {
    static let width: CGFloat = 148
    static let edgePeekInset: CGFloat = 2
    static let edgePeekWidth: CGFloat = 5

    let modes: [MainView.Mode]
    let selected: MainView.Mode
    let floating: Bool
    let onHover: (Bool) -> Void
    let onSelect: (MainView.Mode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(modes.filter { $0 != .settings }) { mode in
                tabButton(mode)
            }

            Spacer()

            if modes.contains(.settings) {
                tabButton(.settings)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(floating ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.primary.opacity(0.025)))
        .overlay(alignment: .trailing) {
            Divider()
        }
        .shadow(color: Color.black.opacity(floating ? 0.12 : 0), radius: floating ? 18 : 0, x: floating ? 8 : 0, y: 0)
        .onHover(perform: onHover)
    }

    private func tabButton(_ mode: MainView.Mode) -> some View {
        let isSelected = selected == mode
        return Button { onSelect(mode) } label: {
            HStack(spacing: 10) {
                Image(systemName: mode.icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20, height: 20)
                Text(mode.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background(
                isSelected ? AnyShapeStyle(Color.chronicleAccent.opacity(0.22))
                           : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: 8),
            )
        }
        .buttonStyle(.plain)
        .help(mode.rawValue)
    }
}

@MainActor
final class MainWindowController: NSObject {
    private var window: NSWindow?
    private let clients: CaptureClients
    private let settingsModel: SettingsModel
    private let navigation = MainWindowNavigation()
    private weak var titlebarSidebarButton: NSButton?

    init(clients: CaptureClients, settingsModel: SettingsModel) {
        self.clients = clients
        self.settingsModel = settingsModel
        super.init()
    }

    func show(mode: MainView.Mode? = nil) {
        if let mode {
            navigation.mode = mode
            if mode == .settings { settingsModel.refreshPending() }
        }
        let w = window ?? makeWindow()
        window = w
        ScreenPlacement.centerOnActiveScreen(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .chronicleMainShown, object: nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false,
        )
        w.title = "Chronicle"
        w.titleVisibility = .hidden
        w.center()
        w.setFrameAutosaveName("ChronicleMainWindow")
        w.isReleasedWhenClosed = false
        // Follow the user to whatever Space (Mission Control desktop) is active
        // instead of yanking them back to the Space where the window was last
        // shown — e.g. a fullscreen app's dedicated Space.
        w.collectionBehavior.insert(.moveToActiveSpace)
        w.contentView = NSHostingView(
            rootView: MainView(clients: clients, navigation: navigation, settingsModel: settingsModel)
                .tint(.chronicleAccent),
        )
        installTitlebarControls(on: w)
        return w
    }

    private func installTitlebarControls(on window: NSWindow) {
        guard titlebarSidebarButton == nil,
              let zoomButton = window.standardWindowButton(.zoomButton),
              let titlebar = zoomButton.superview
        else { return }
        let button = HoverSidebarButton(
            image: sidebarImage(),
            target: self,
            action: #selector(toggleSidebarTabs),
        )
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryPushIn)
        button.toolTip = navigation.tabsExpanded ? "Collapse tabs" : "Expand tabs"
        button.onHoverChange = { [weak self] hovering in
            self?.navigation.setTabsButtonHovering(hovering)
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: zoomButton.trailingAnchor, constant: 20),
            button.centerYAnchor.constraint(equalTo: zoomButton.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        titlebarSidebarButton = button
        // No visible "Chronicle" label: the window title stays set for Mission
        // Control and accessibility, but the titlebar itself shows only the
        // traffic lights and the sidebar toggle — the app is its one window.
    }

    @objc private func toggleSidebarTabs() {
        navigation.toggleTabsExpanded()
        titlebarSidebarButton?.image = sidebarImage()
        titlebarSidebarButton?.toolTip = navigation.tabsExpanded ? "Collapse tabs" : "Expand tabs"
    }

    private func sidebarImage() -> NSImage {
        NSImage(
            systemSymbolName: navigation.tabsExpanded ? "sidebar.left" : "sidebar.right",
            accessibilityDescription: navigation.tabsExpanded ? "Collapse tabs" : "Expand tabs",
        ) ?? NSImage()
    }
}

private final class HoverSidebarButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?

    private static let hoverSize = NSSize(width: 22, height: 22)
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let hoverRect = bounds.centeredRect(size: Self.hoverSize)
        let trackingArea = NSTrackingArea(
            rect: hoverRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil,
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}

private extension NSRect {
    func centeredRect(size: NSSize) -> NSRect {
        NSRect(
            x: midX - size.width / 2,
            y: midY - size.height / 2,
            width: size.width,
            height: size.height,
        )
    }
}
