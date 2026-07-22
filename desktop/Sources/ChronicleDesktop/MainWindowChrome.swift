import AppKit
import SwiftUI

// Window chrome for the main window, extracted from MainView.swift: the
// persisted navigation model, the collapsible tab rail, the NSWindow
// controller with its titlebar controls, and the hover-tracking sidebar
// button. No capture state lives here.

@MainActor
final class MainWindowSidebarHoverState: ObservableObject {
    @Published private(set) var peeking = false

    private var buttonHovering = false
    private var railHovering = false
    private var suppressed = false

    var railPeeking: Bool {
        suppressed == false && railHovering
    }

    func setButtonHovering(_ hovering: Bool) {
        if hovering == false, suppressed {
            suppressed = false
        }
        guard buttonHovering != hovering else {
            updatePeeking()
            return
        }
        buttonHovering = hovering
        updatePeeking()
    }

    func setRailHovering(_ hovering: Bool) {
        guard railHovering != hovering else { return }
        railHovering = hovering
        updatePeeking()
    }

    func setSuppressed(_ suppressed: Bool) {
        guard self.suppressed != suppressed else { return }
        self.suppressed = suppressed
        updatePeeking()
    }

    private func updatePeeking() {
        let next = suppressed == false && (buttonHovering || railHovering)
        guard peeking != next else { return }
        peeking = next
    }
}

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

    @Published private(set) var suppressTabsExpandedAnimation = false
    let sidebarHover = MainWindowSidebarHoverState()
    private var tabsAnimationSuppressionTask: Task<Void, Never>?

    var tabsPeeking: Bool {
        sidebarHover.peeking
    }

    var tabsRailPeeking: Bool {
        sidebarHover.railPeeking
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
        sidebarHover.setButtonHovering(hovering)
    }

    func setTabsRailHovering(_ hovering: Bool) {
        sidebarHover.setRailHovering(hovering)
    }

    func toggleTabsExpanded() {
        let shouldSuppressExpansionAnimation = tabsExpanded == false && tabsPeeking
        setTabsExpandedAnimationSuppressed(shouldSuppressExpansionAnimation)
        tabsExpanded.toggle()
        if tabsExpanded {
            // The collapsed overlay is about to leave the hierarchy, so it can no
            // longer deliver a matching mouseExited event for its tracking area.
            sidebarHover.setRailHovering(false)
            sidebarHover.setSuppressed(false)
        } else {
            sidebarHover.setSuppressed(true)
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

enum MainWindowLayout {
    static let minimumSize = NSSize(width: 700, height: 520)
    static let titlebarInset: CGFloat = 38
}

struct MainTabRail: View {
    @ObservedObject private var localization = DesktopLocalization.shared
    static let width: CGFloat = 148
    static let edgePeekInset: CGFloat = 2
    static let edgePeekWidth: CGFloat = 5
    // Adjacent navigation rows must share a boundary. Any positive VStack
    // spacing creates a strip that belongs to neither button and ignores clicks.
    static let itemSpacing: CGFloat = 0
    // Roughly three CJK characters at the sidebar's text size. This is a
    // spatial tolerance, not a close delay: once the pointer leaves this
    // region the floating rail still dismisses immediately.
    static let hoverBufferWidth: CGFloat = 54
    static let collapsedHoverWidth = edgePeekInset + edgePeekWidth
    static let floatingHoverWidth = width + hoverBufferWidth

    let modes: [MainView.Mode]
    let selected: MainView.Mode
    let floating: Bool
    let onSelect: (MainView.Mode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            ForEach(modes.filter { $0 != .settings }) { mode in
                tabButton(mode)
            }

            Spacer()

            if modes.contains(.settings) {
                Divider()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
                tabButton(.settings)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, MainWindowLayout.titlebarInset + 14)
        .padding(.bottom, 14)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Color.chronicleSidebar)
        .overlay(alignment: .trailing) {
            Color.primary.opacity(0.08)
            .frame(width: 1)
        }
        .shadow(color: Color.black.opacity(floating ? 0.12 : 0), radius: floating ? 18 : 0, x: floating ? 8 : 0, y: 0)
    }

    private func tabButton(_ mode: MainView.Mode) -> some View {
        let isSelected = selected == mode
        return Button { onSelect(mode) } label: {
            HStack(spacing: 10) {
                Image(systemName: mode.icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20, height: 20)
                Text(mode.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background(
                isSelected ? AnyShapeStyle(Color.primary.opacity(0.08))
                           : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: 8),
            )
            // The visible wash may be rounded, but hit targets must tile the
            // whole rail with no dead corner or boundary pixels.
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle())
        .help(mode.title)
        .accessibilityIdentifier("main-navigation-\(mode.rawValue.lowercased())")
    }
}

/// One continuous tracking region grows from the edge trigger to the rail plus
/// its spatial tolerance. Keeping the same view alive avoids an exit/enter
/// handoff between two sensors, which used to retrigger the peek transition.
/// Tracking does not intercept clicks, so content under the buffer stays active.
struct SidebarHoverRegion: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> SidebarHoverTrackingView {
        let view = SidebarHoverTrackingView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ view: SidebarHoverTrackingView, context: Context) {
        view.onHover = onHover
    }
}

final class SidebarHoverTrackingView: NSView {
    var onHover: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil,
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}

private struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageChanged),
            name: .chronicleLanguageChanged,
            object: nil,
        )
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
            contentRect: NSRect(origin: .zero, size: MainWindowLayout.minimumSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false,
        )
        w.title = "Chronicle"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        w.backgroundColor = .windowBackgroundColor
        w.center()
        w.setFrameAutosaveName("ChronicleMainWindow")
        w.isReleasedWhenClosed = false
        // No relaunch restoration: macOS would reopen the window uninvited on
        // whatever Space is active — including over a fullscreen app. The menu
        // bar icon is one click; frame autosave still remembers the position.
        w.isRestorable = false
        // Follow the user to the active Space instead of yanking them back to
        // the Space the window was last shown on. Over a fullscreen Space this
        // means overlaying the fullscreen app — accepted behavior for an
        // explicit open (2026-07-09; probe-verified that every programmatic
        // show path lands there anyway, flag or no flag).
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
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryPushIn)
        button.toolTip = navigation.tabsExpanded ? L("Collapse tabs") : L("Expand tabs")
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
        titlebarSidebarButton?.toolTip = navigation.tabsExpanded ? L("Collapse tabs") : L("Expand tabs")
    }

    @objc private func languageChanged() {
        titlebarSidebarButton?.toolTip = navigation.tabsExpanded
            ? L("Collapse tabs") : L("Expand tabs")
        titlebarSidebarButton?.image = sidebarImage()
    }

    private func sidebarImage() -> NSImage {
        NSImage(
            systemSymbolName: navigation.tabsExpanded ? "sidebar.left" : "sidebar.right",
            accessibilityDescription: navigation.tabsExpanded ? L("Collapse tabs") : L("Expand tabs"),
        ) ?? NSImage()
    }
}

private final class HoverSidebarButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?

    private static let hoverSize = NSSize(width: 22, height: 22)
    private var hoverTrackingArea: NSTrackingArea?
    private var hovering = false {
        didSet { updateVisualState() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        updateVisualState()
    }

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
        hovering = true
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovering = false
        onHoverChange?(false)
    }

    private func updateVisualState() {
        contentTintColor = hovering ? .labelColor : .secondaryLabelColor
        layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(hovering ? 0.08 : 0)
            .cgColor
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
