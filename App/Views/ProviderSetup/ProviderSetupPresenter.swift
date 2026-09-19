import Combine
import Foundation

#if os(macOS)
import AppKit

/// The one way to open the setup sheet, from anywhere.
///
/// The sheet belongs to the dashboard window, but the menu-bar popover has to be
/// able to raise it too, and the popover lives outside the SwiftUI scene. This
/// carries the request across that boundary; `DashboardView` binds to
/// `isPresented`.
@MainActor
final class ProviderSetupPresenter: ObservableObject {
    static let shared = ProviderSetupPresenter()

    @Published var isPresented = false

    private init() {}

    /// Raises the dashboard, then asks it to present the sheet.
    ///
    /// A sheet needs a visible parent window. In headless (`.accessory`) mode
    /// the dashboard may be closed, in which case the window has to come back
    /// before the request means anything.
    func present() {
        // Plain activation: the user clicked our menu bar item, so coming
        // forward is expected. `ignoringOtherApps` yanked focus away from
        // whatever they were actually using.
        NSApp.activate()

        if let window = dashboardWindow {
            window.makeKeyAndOrderFront(nil)
            isPresented = true
            return
        }

        // No dashboard window: ask AppKit to restore one, then present once it
        // exists. `newWindowForTab` is what the standard Window menu uses, and
        // it round-trips through the same `WindowGroup`.
        NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
        DispatchQueue.main.async { [weak self] in
            self?.dashboardWindow?.makeKeyAndOrderFront(nil)
            self?.isPresented = true
        }
    }

    /// The dashboard is the app's only `WindowGroup` window; the pinned HUD
    /// panels are `NSPanel`s and the popover is not a window we own.
    private var dashboardWindow: NSWindow? {
        NSApp.windows.first { window in
            window.isVisible
                && !(window is NSPanel)
                && window.contentViewController != nil
                && window.styleMask.contains(.titled)
        }
    }
}

#endif
