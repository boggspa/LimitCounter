import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let appState: AppStateStore

    init(appState: AppStateStore) {
        self.appState = appState
        super.init()
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "star.bubble.fill", accessibilityDescription: "AI Usage")
        }
        updateMenu()
    }

    func updateMenu() {
        let menu = NSMenu()

        let snapshots = appState.snapshots.filter { $0.hasContent }

        if snapshots.isEmpty {
            menu.addItem(NSMenuItem(title: "No data available", action: nil, keyEquivalent: ""))
        } else {
            for snapshot in snapshots {
                let headerItem = NSMenuItem(title: snapshot.displayName, action: nil, keyEquivalent: "")
                headerItem.isEnabled = false
                menu.addItem(headerItem)

                // Show top 2 windows
                for window in snapshot.windows.prefix(2) {
                    let title = "  \(window.label): \(window.leadingValueText)"
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
                menu.addItem(NSMenuItem.separator())
            }
        }

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshAction), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let showAppItem = NSMenuItem(title: "Show Main Window", action: #selector(showAppAction), keyEquivalent: "0")
        showAppItem.target = self
        menu.addItem(showAppItem)

        menu.addItem(NSMenuItem.separator())

        let headlessItem = NSMenuItem(title: "Headless Mode", action: #selector(toggleHeadlessAction), keyEquivalent: "")
        headlessItem.state = appState.isHeadlessMode ? .on : .off
        headlessItem.target = self
        menu.addItem(headlessItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc private func refreshAction() {
        Task {
            await appState.refresh()
            updateMenu()
        }
    }

    @objc private func showAppAction() {
        appState.isHeadlessMode = false
    }

    @objc private func toggleHeadlessAction() {
        appState.isHeadlessMode.toggle()
        updateMenu()
    }
}
#endif
