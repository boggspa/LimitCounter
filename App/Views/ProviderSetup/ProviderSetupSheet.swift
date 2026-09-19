import SwiftUI

#if os(macOS)

/// The single setup surface, replacing the per-provider `NSWindow` swarm.
///
/// It is a sheet on the dashboard rather than a window of its own: a sheet
/// cannot end up behind another app, does not appear in Mission Control or the
/// window cycle, inherits the app's environment and colour scheme, and cannot
/// be left floating above everything the way `window.level = .floating` did.
struct ProviderSetupSheet: View {
    @ObservedObject var model: ProviderSetupModel
    var onRefresh: () -> Void
    var lastSyncDate: Date?
    var onClose: () -> Void

    @State private var showDiscardConfirmation = false

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(intensity: .settings)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                ProviderSetupRail(model: model)
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
        // Sized for the largest page rather than resized per page: a sheet that
        // animates its window frame on every rail click is the jank being
        // removed. The embedded browsers need 760x720, plus the 240pt rail and
        // the 44pt title bar.
        .frame(width: 1020, height: 780)
        .background(SheetWindowConfigurator())
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
            // Steps advance inside the canvas rather than pushing a stack, so
            // "back" is one level and only exists on the form page.
            if case .credential(let providerID) = model.page {
                Button {
                    model.page = .provider(providerID)
                } label: {
                    Label(providerID.displayName, systemImage: "chevron.left")
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
        case .provider(let id), .credential(let id): return id.displayName
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
