import SwiftUI

#if os(macOS)

/// The setup sheet's left rail: navigation and status only, deliberately quiet.
///
/// Rows are grouped by status because the two questions people actually arrive
/// with are "what is broken?" and "what have I not done yet?". Each state has a
/// distinct glyph *shape* as well as a colour, so reading down the leading
/// gutter gives the whole picture before any colour is processed.
struct ProviderSetupRail: View {
    @ObservedObject var model: ProviderSetupModel
    /// Extra space above the first row, for the window's traffic lights. A
    /// padding rather than a safe-area inset: an inset spacer is flexible in
    /// width and makes the rail stretch in its `HStack`.
    var topInset: CGFloat = 0
    @State private var showAddProvider = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    overviewRow

                    section("Needs attention", model.attentionProviderIDs)
                    section("Connected", model.connectedProviderIDs)
                    section("Not set up", model.notSetUpProviderIDs)
                }
                .padding(.horizontal, 10)
                .padding(.top, 12 + topInset)
                .padding(.bottom, 12)
            }
            .scrollContentBackground(.hidden)

            Divider().opacity(0.18)

            footer
        }
        .frame(width: 240)
        .background(
            GlassPanel(
                style: .darkPanel,
                accent: .white,
                shape: Rectangle(),
                intensity: .settings
            )
        )
    }

    // MARK: Rows

    private var overviewRow: some View {
        Button {
            model.page = .overview
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 14)
                Text("Overview")
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selectionBackground(isSelected: model.page == .overview, accent: .white))
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func section(_ title: String, _ providerIDs: [ProviderID]) -> some View {
        if !providerIDs.isEmpty {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                // The count is the second colour-free channel: "NEEDS
                // ATTENTION 2" tells the story with no amber pixels at all.
                Text("\(providerIDs.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), \(providerIDs.count)")

            ForEach(providerIDs, id: \.self) { providerID in
                row(for: providerID)
            }
        }
    }

    private func row(for providerID: ProviderID) -> some View {
        let health = model.health(for: providerID)
        let isSelected = model.selectedProviderID == providerID
        let accent = Color(hex: providerID.accentColorHex)

        return Button {
            model.page = .provider(providerID)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                statusGlyph(health, accent: accent)
                    .frame(width: 16, alignment: .leading)
                    .padding(.top, health.isAttention ? 1 : 0)

                ProviderBrandIconView(providerID: providerID, size: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(providerID.displayName)
                        .font(.subheadline)
                        .fontWeight(health.isAttention ? .semibold : .regular)
                        .foregroundStyle(health == .notSetUp ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    // Only attention rows get a second line, because only they
                    // have something to say.
                    if case .needsAttention(let message) = health {
                        Text(shortAttentionLine(message))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selectionBackground(isSelected: isSelected, accent: accent))
        .accessibilityLabel("\(providerID.displayName), \(health.word)")
    }

    @ViewBuilder
    private func statusGlyph(_ health: ProviderSetupHealth, accent: Color) -> some View {
        // 7pt was too small to read on a scaled display — the shapes blurred
        // into one another, which defeats the point of using shape as the
        // primary channel.
        switch health {
        case .connected:
            Circle()
                .fill(accent)
                .frame(width: 9, height: 9)
        case .autoDetected:
            Circle()
                .strokeBorder(accent, lineWidth: 2)
                .frame(width: 9, height: 9)
        case .needsAttention:
            // Angular and pointing up: distinguishable from the discs by shape
            // alone, at a glance, without colour.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: "#F59E0B"))
        case .notSetUp:
            Circle()
                .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.4)
                .frame(width: 9, height: 9)
        }
    }

    @ViewBuilder
    private func selectionBackground(isSelected: Bool, accent: Color) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(accent.opacity(isSelected ? 0.16 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(accent.opacity(isSelected ? 0.30 : 0), lineWidth: 0.8)
            )
    }

    /// Sync errors are written for a settings row, not a 240pt rail. Take the
    /// first sentence and let the page show the rest.
    private func shortAttentionLine(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = trimmed.firstIndex(where: { $0 == "." || $0 == "\n" }) else { return trimmed }
        return String(trimmed[trimmed.startIndex..<end])
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                showAddProvider = true
            } label: {
                footerLabel("plus", "Add provider")
            }
            .buttonStyle(.plain)
            .disabled(model.disabledProviderIDs.isEmpty)
            .opacity(model.disabledProviderIDs.isEmpty ? 0.4 : 1)
            .popover(isPresented: $showAddProvider, arrowEdge: .trailing) {
                AddProviderPopover(model: model, isPresented: $showAddProvider)
            }

            Button {
                model.page = .preferences
            } label: {
                footerLabel("gearshape", "Preferences")
            }
            .buttonStyle(.plain)
            .background(selectionBackground(isSelected: model.page == .preferences, accent: .white))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private func footerLabel(_ systemImage: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 14)
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Re-enabling a provider is the mirror of removing one, and lives in exactly
/// one place so removal is never a dead end.
private struct AddProviderPopover: View {
    @ObservedObject var model: ProviderSetupModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add provider")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            if model.disabledProviderIDs.isEmpty {
                Text("Nothing else to add.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.disabledProviderIDs, id: \.self) { providerID in
                    HStack(spacing: 8) {
                        ProviderBrandIconView(providerID: providerID, size: 16)
                        Text(providerID.displayName)
                            .font(.subheadline)
                        Spacer(minLength: 12)
                        Button("Add") {
                            model.enable(providerID)
                            isPresented = false
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 220)
    }
}

#endif
