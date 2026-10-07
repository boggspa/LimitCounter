import Combine
import Foundation
import SwiftUI

#if os(macOS)
import AppKit

/// The one way to open the setup window, from anywhere.
///
/// The setup surface is a free-standing Liquid Glass window rather than a sheet
/// on the dashboard: it can be dragged anywhere on the desktop, the dashboard
/// stays usable behind it, and it no longer needs the dashboard window to exist
/// at all, which matters in headless (`.accessory`) mode where the dashboard is
/// usually closed. The menu-bar popover lives outside the SwiftUI scene, so this
/// carries the request across that boundary and owns the window itself.
@MainActor
final class ProviderSetupPresenter: NSObject, ObservableObject {
    static let shared = ProviderSetupPresenter()

    /// Mirrors the window's visibility for anything that wants to observe it.
    @Published private(set) var isPresented = false

    /// Bumped when the window's close button is clicked while there are unsaved
    /// edits. The window content observes it and runs the same discard
    /// confirmation the Done button uses, so the red button never silently
    /// throws edits away and never ignores the click either.
    @Published private(set) var closeRequestCount = 0

    /// Fixed layout: the embedded browsers need 760x720, plus the 240pt rail and
    /// the 44pt title bar. A window that resized per page is the jank the old
    /// per-provider window swarm had.
    static let windowSize = NSSize(width: 1020, height: 780)
    static let cornerRadius: CGFloat = 22
    private static let frameAutosaveName = "ProviderSetupWindow"

    let model = ProviderSetupModel()

    private weak var appState: AppStateStore?
    private var window: NSWindow?

    private override init() {
        super.init()
    }

    /// Hands over the shared app state. Idempotent; the dashboard and the menu
    /// bar both call it so whichever appears first wins and later calls are
    /// no-ops.
    func configure(appState: AppStateStore) {
        if self.appState == nil || self.appState !== appState {
            self.appState = appState
        }
    }

    /// Raises the setup window, creating it on first use.
    func present() {
        guard let appState else {
            assertionFailure("ProviderSetupPresenter.present() before configure(appState:)")
            return
        }

        // Plain activation: the user clicked our menu bar item or a dashboard
        // control, so coming forward is expected. `ignoringOtherApps` yanked
        // focus away from whatever they were actually using.
        NSApp.activate()

        // Load before the first render, not in `onAppear`: otherwise the rail's
        // first pass sees an empty health map, every row builds itself as
        // "Not set up", and the accessibility labels stay that way even after
        // the visuals correct themselves a frame later.
        model.load(syncErrors: appState.syncErrors)

        let window = self.window ?? makeWindow(appState: appState)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        isPresented = true
    }

    /// Closes the window without the unsaved-edits check; callers have already
    /// run it (Done, or Discard in the confirmation).
    func dismiss() {
        window?.close()
    }

    // MARK: Window

    private func makeWindow(appState: AppStateStore) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Limit Counter Setup"
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Liquid Glass chrome: the window itself paints nothing, and an
        // `NSGlassEffectView` supplies the refractive surface the content sits
        // on, so the desktop and whatever is behind the window show through.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The whole app is dark; glass should render in its dark variant
        // regardless of the system appearance so the white-on-dark controls
        // stay readable over a light desktop.
        window.appearance = NSAppearance(named: .darkAqua)
        // Any empty surface drags the window, so it can be parked anywhere.
        // Controls, lists and the embedded browsers still own their own drags.
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = Self.cornerRadius
        glass.tintColor = NSColor(red: 0.02, green: 0.025, blue: 0.04, alpha: 0.42)

        let hosting = NSHostingView(
            rootView: ProviderSetupSheet(
                model: model,
                onRefresh: { Task { await appState.refresh(userInitiated: true) } },
                lastSyncDate: appState.lastSyncDate,
                onClose: { [weak self] in self?.dismiss() }
            )
            .environmentObject(appState)
            .preferredColorScheme(.dark)
        )
        // The presenter sizes the window; if the hosting view also pushed its
        // fitting size into the window, AppKit would add a title-bar height on
        // top and leave a blank strip under the content.
        hosting.sizingOptions = []
        glass.contentView = hosting
        window.contentView = glass

        // Remember where the user parked it; first launch opens over the
        // dashboard, or centred on screen when the dashboard is closed. The
        // size is always ours: even with `.fullSizeContentView` AppKit adds a
        // title-bar height when it turns the content rect into a frame, which
        // would leave a blank strip under the content.
        let restored = window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)
        var frame = NSRect(origin: .zero, size: Self.windowSize)
        if restored {
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - Self.windowSize.height)
        } else if let anchor = (dashboardWindow?.frame ?? NSScreen.main?.visibleFrame) {
            frame.origin = NSPoint(
                x: anchor.midX - Self.windowSize.width / 2,
                y: anchor.midY - Self.windowSize.height / 2
            )
        }
        window.setFrame(window.constrainFrameRect(frame, to: window.screen ?? NSScreen.main), display: false)
        return window
    }

    /// The dashboard is the app's only `WindowGroup` window; the pinned HUD
    /// panels are `NSPanel`s and the popover is not a window we own.
    private var dashboardWindow: NSWindow? {
        NSApp.windows.first { candidate in
            candidate.isVisible
                && candidate !== window
                && !(candidate is NSPanel)
                && candidate.contentViewController != nil
                && candidate.styleMask.contains(.titled)
        }
    }
}

extension ProviderSetupPresenter: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.hasUnsavedEdits else { return true }
        closeRequestCount += 1
        return false
    }

    func windowWillClose(_ notification: Notification) {
        isPresented = false
    }
}

#endif
