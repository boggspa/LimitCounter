import SwiftUI

#if os(macOS)

/// The single setup surface, replacing the per-provider `NSWindow` swarm.
///
/// `ProviderSetupPresenter` hosts it in one free-standing Liquid Glass window
/// (an `NSGlassEffectView` on a transparent `NSWindow`), so this paints no
/// backdrop of its own: the glass is the chrome, and only a thin ink wash sits
/// between it and the content for contrast over bright desktops.
struct ProviderSetupSheet: View {
    @ObservedObject var model: ProviderSetupModel
    var onRefresh: () -> Void
    var lastSyncDate: Date?
    var onClose: () -> Void

    @ObservedObject private var presenter = ProviderSetupPresenter.shared
    @State private var showDiscardConfirmation = false

    var body: some View {
        ZStack {
            ProGlassTheme.ink.opacity(0.22)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                // The window's traffic lights sit in this corner; the rail
                // keeps its first row clear of them.
                ProviderSetupRail(model: model, topInset: 30)
                Divider().opacity(0.18)
                VStack(spacing: 0) {
                    titleBar
                    Divider().opacity(0.14)
                    ProviderSetupCanvas(
                        model: model,
                        onRefresh: onRefresh,
                        lastSyncDate: lastSyncDate
                    )
                }
            }
        }
        // Sized for the largest page rather than resized per page: a window
        // that animates its frame on every rail click is the jank being
        // removed. The presenter sizes the window to match.
        .frame(
            width: ProviderSetupPresenter.windowSize.width,
            height: ProviderSetupPresenter.windowSize.height
        )
        // Full-size content: the layout above accounts for the title bar, so
        // the host must not inset it a second time.
        .ignoresSafeArea()
        // The window's close button lands here when there are unsaved edits.
        .onChange(of: presenter.closeRequestCount) { _ in attemptClose() }
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: $showDiscardConfirmation
        ) {
            Button("Discard", role: .destructive, action: onClose)
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Some provider details have not been saved yet.")
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            // The traffic lights sit over the rail, not here, so this strip
            // starts flush. It doubles as the window's main drag handle.
            // Steps advance inside the canvas rather than pushing a stack, so
            // "back" is one level and only exists on the form page.
            if case .credential(let account) = model.page {
                Button {
                    model.page = .provider(account.providerID)
                } label: {
                    Label(account.providerID.displayName, systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Done", action: attemptClose)
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                // Escape closes, but never silently discards edits.
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var title: String {
        switch model.page {
        case .overview: return "Setup"
        case .provider(let id): return id.displayName
        case .credential(let account):
            if let label = model.accountLabel(for: account) {
                return "\(account.providerID.displayName) · \(label)"
            }
            return account.providerID.displayName
        case .preferences: return "Preferences"
        }
    }

    private func attemptClose() {
        if model.hasUnsavedEdits {
            showDiscardConfirmation = true
        } else {
            onClose()
        }
    }
}

#endif
