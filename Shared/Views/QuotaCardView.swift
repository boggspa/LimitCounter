import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct ProviderBrandIconView: View {
    let providerID: ProviderID
    let size: CGFloat

    public init(providerID: ProviderID, size: CGFloat = 22) {
        self.providerID = providerID
        self.size = size
    }

    private var accentColor: Color {
        Color(hex: providerID.accentColorHex)
    }

    public var body: some View {
        ZStack {
            if !iconUsesOriginalColors {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(accentColor.opacity(0.12))

                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(accentColor.opacity(0.18), lineWidth: 1)
            } else if providerID == .openai {
                // Codex special dark background for terminal icon
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(Color.black.opacity(0.45))
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            }

            icon
                .resizable()
                .renderingMode(iconUsesOriginalColors ? .original : .template)
                .scaledToFit()
                .padding(iconUsesOriginalColors ? 0 : size * 0.18)
                .foregroundStyle(iconUsesOriginalColors ? .primary : accentColor)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        }
        .frame(width: size, height: size)
    }

    private var iconUsesOriginalColors: Bool {
        #if os(macOS)
        if providerID.appIconImage != nil { return true }
        #endif
        if bundledLogoImage != nil { return true }
        return false
    }

    private var icon: Image {
        #if os(macOS)
        if let nsImage = providerID.appIconImage {
            return Image(nsImage: nsImage)
        }
        #endif

        if let bundledLogoImage {
            #if os(macOS)
            return Image(nsImage: bundledLogoImage)
            #else
            return Image(uiImage: bundledLogoImage)
            #endif
        }

        return Image(systemName: providerID.iconName)
    }

    #if os(macOS)
    private var bundledLogoImage: NSImage? {
        if providerID == .openai { return nil } // Favor SF symbol for Codex consistency
        let assetName = providerID.bundledLogoAssetName
        guard !assetName.isEmpty else { return nil }
        return NSImage(named: assetName)
    }
    #elseif canImport(UIKit)
    private var bundledLogoImage: UIImage? {
        if providerID == .openai { return nil } // Favor SF symbol for Codex consistency
        return providerID.bundledLogoImage
    }
    #endif
}

public struct ProviderCardTitleText: View {
    let title: String
    let accentColor: Color

    public init(title: String, accentColor: Color) {
        self.title = title
        self.accentColor = accentColor
    }

    public var body: some View {
        Text(title)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: accentColor.opacity(0.18), radius: 6, x: 0, y: 0)
            .overlay {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(accentColor.opacity(0.10))
                    .blur(radius: 0.6)
                    .offset(x: 0.3, y: 0.2)
                    .mask(
                        Text(title)
                            .font(.headline.weight(.semibold))
                    )
            }
    }
}

/// How stale a snapshot's `fetchedAt` is, used to escalate the "Updated …"
/// line from quiet tertiary text to a prominent amber/red warning. This is
/// what surfaces an iOS viewer that has fallen hours/days behind the Mac
/// publisher (CloudKit silent-push / background-refresh starvation) at a
/// glance. On macOS the app refreshes locally, so it effectively never trips.
private enum SnapshotStaleness {
    case fresh
    case stale
    case veryStale

    static let staleThreshold: TimeInterval = 12 * 60 * 60      // 12 hours
    static let veryStaleThreshold: TimeInterval = 24 * 60 * 60  // 24 hours

    init(age: TimeInterval) {
        if age >= Self.veryStaleThreshold {
            self = .veryStale
        } else if age >= Self.staleThreshold {
            self = .stale
        } else {
            self = .fresh
        }
    }

    /// nil when fresh (keep the original quiet tertiary styling).
    var warningColor: Color? {
        switch self {
        case .fresh: return nil
        case .stale: return Color(hex: "#F59E0B")      // amber — matches meter severity
        case .veryStale: return Color(hex: "#DC2626")  // red — matches meter severity
        }
    }
}

@ViewBuilder
private func updatedMetadataLabel(_ text: String, staleness: SnapshotStaleness) -> some View {
    if let color = staleness.warningColor {
        HStack(spacing: 3) {
            Image(systemName: "clock.badge.exclamationmark")
            Text(text)
        }
        .foregroundStyle(color)
        .fontWeight(.semibold)
    } else {
        Text(text)
            .foregroundStyle(.tertiary)
    }
}

@ViewBuilder
private func headerMetadataLine(plan: String?, updatedAt: Date) -> some View {
    let updatedText = "Updated \(updatedAt.relativeString)"
    let staleness = SnapshotStaleness(age: Date().timeIntervalSince(updatedAt))

    if let plan, !plan.isEmpty {
        HStack(spacing: 4) {
            Text(plan)
                .foregroundStyle(.secondary)
            Text("-")
                .foregroundStyle(.tertiary)
            updatedMetadataLabel(updatedText, staleness: staleness)
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.78)
    } else {
        updatedMetadataLabel(updatedText, staleness: staleness)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
    }
}

// MARK: - Quota Card (full app size)

public struct QuotaCardView: View {
    let snapshot: QuotaSnapshot
    let isRefreshing: Bool
    @StateObject private var disclosureStore = ProviderCardDisclosureStore.shared

    public init(snapshot: QuotaSnapshot) {
        self.init(snapshot: snapshot, isRefreshing: false)
    }

    public init(snapshot: QuotaSnapshot, isRefreshing: Bool) {
        self.snapshot = snapshot
        self.isRefreshing = isRefreshing
    }

    private var accentColor: Color {
        Color(hex: snapshot.providerID.accentColorHex)
    }

    private var showsTelemetryDetails: Bool {
        disclosureStore.isExpanded(for: snapshot.providerID)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            Divider().overlay(Color.white.opacity(0.10))
            cardBody
        }
        .overlay(alignment: .topTrailing) {
            if hasTelemetryContent {
                telemetryToggleButton
                    .padding(.top, 8)
                    .padding(.trailing, 8)
            }
        }
        // Apply Liquid Glass via the new container-level modifier
        // instead of `.background(GlassPanel(...))`. The modifier
        // routes `.regularMaterial` + `.glassEffect()` at the correct
        // z-order so card content stays foreground regardless of
        // backing-material density.
        .glassCardBackground(accent: accentColor, cornerRadius: 16)
        .overlay {
            if isRefreshing {
                RefreshHaloOverlay(accentColor: accentColor, cornerRadius: 16)
            }
        }
    }

    // MARK: - Header

    private var cardHeader: some View {
        HStack(spacing: 8) {
            ProviderBrandIconView(providerID: snapshot.providerID, size: 24)

            VStack(alignment: .leading, spacing: 1) {
                ProviderCardTitleText(title: snapshot.displayName, accentColor: accentColor)

                headerMetadataLine(plan: snapshot.planName, updatedAt: snapshot.fetchedAt)
            }

            Spacer()

            fetchStateIndicator
        }
        .padding(10)
        .background(
            LinearGradient(
                colors: [
                    accentColor.opacity(0.13),
                    accentColor.opacity(0.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    @ViewBuilder
    private var fetchStateIndicator: some View {
        switch snapshot.fetchState {
        case .success:
            EmptyView()
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 16))
        case .notConfigured:
            Image(systemName: "gear")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var cardBody: some View {
        switch snapshot.fetchState {
        case .success:
            if !snapshot.hasContent {
                Text("No usage data available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if showsTelemetryDetails, !snapshot.signals.isEmpty {
                        supplementalSection(title: "Recent Changes") {
                            VStack(spacing: 6) {
                                ForEach(snapshot.signals.prefix(2)) { signal in
                                    SnapshotSignalNotice(signal: signal, accentColor: accentColor)
                                }
                            }
                        }
                    }

                    let windows = snapshot.summaryWindows
                    if !windows.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(windows) { window in
                                QuotaWindowRow(window: window, accentColor: accentColor, providerID: snapshot.providerID)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(accentColor.opacity(0.06))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .strokeBorder(
                                                        LinearGradient(
                                                            colors: [
                                                                Color.white.opacity(0.13),
                                                                Color.white.opacity(0.03)
                                                            ],
                                                            startPoint: .topLeading,
                                                            endPoint: .bottomTrailing
                                                        ),
                                                        lineWidth: 0.5
                                                    )
                                            )
                                    )
                            }
                        }
                    }

                    if showsTelemetryDetails, snapshot.providerID != .kimi,
                       let statsTitle = snapshot.statsSectionTitle {
                        supplementalSection(title: statsTitle) {
                            SnapshotMetricListView(
                                items: snapshot.stats.map {
                                    SnapshotMetricItem(
                                        id: $0.id,
                                        title: $0.label,
                                        value: $0.valueText,
                                        subtitle: $0.subtitle
                                    )
                                },
                                accentColor: accentColor
                            )
                        }
                    }

                    if showsTelemetryDetails, snapshot.providerID != .kimi,
                       let balancesTitle = snapshot.balancesSectionTitle {
                        supplementalSection(title: balancesTitle) {
                            SnapshotMetricListView(
                                items: snapshot.balances.map {
                                    SnapshotMetricItem(
                                        id: $0.id,
                                        title: $0.label,
                                        value: $0.valueText,
                                        subtitle: $0.subtitle ?? $0.resetDate.map { "Resets \($0.countdownString)" }
                                    )
                                },
                                accentColor: accentColor
                            )
                        }
                    }
                }
                .padding(10)
            }

        case .error:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text("Update failed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)

        case .notConfigured:
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.secondary)
                Text("Configure a credential you control")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    // MARK: - Footer

    private var hasTelemetryContent: Bool {
        if !snapshot.signals.isEmpty { return true }
        if snapshot.providerID == .kimi { return false }
        return !snapshot.stats.isEmpty || !snapshot.balances.isEmpty
    }

    private var telemetryToggleButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                disclosureStore.toggle(snapshot.providerID)
            }
        } label: {
            Image(systemName: "tablecells.fill.badge.ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(showsTelemetryDetails ? accentColor : .white)
                .background(
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(accentColor.opacity(0.28), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsTelemetryDetails ? "Hide telemetry details" : "Show telemetry details")
    }

    private func supplementalSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            content()
        }
    }

    // MARK: - Background

    private var cardBackground: some View {
        ZStack {
            Color(hex: "#141420")
            LinearGradient(
                colors: [accentColor.opacity(0.06), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - Combined Codex Card

public struct CodexOverviewCardView: View {
    let usageSnapshot: QuotaSnapshot
    let telemetrySnapshot: QuotaSnapshot?
    let isRefreshing: Bool
    @StateObject private var disclosureStore = ProviderCardDisclosureStore.shared

    public init(usageSnapshot: QuotaSnapshot, telemetrySnapshot: QuotaSnapshot?) {
        self.init(usageSnapshot: usageSnapshot, telemetrySnapshot: telemetrySnapshot, isRefreshing: false)
    }

    public init(usageSnapshot: QuotaSnapshot, telemetrySnapshot: QuotaSnapshot?, isRefreshing: Bool) {
        self.usageSnapshot = usageSnapshot
        self.telemetrySnapshot = telemetrySnapshot
        self.isRefreshing = isRefreshing
    }

    private var accentColor: Color {
        Color(hex: usageSnapshot.providerID.accentColorHex)
    }

    private var telemetryRows: [QuotaStat] {
        telemetrySnapshot?.stats ?? []
    }

    private var telemetrySignals: [QuotaSignal] {
        telemetrySnapshot?.signals ?? []
    }

    private var telemetryBalances: [QuotaBalance] {
        telemetrySnapshot?.balances ?? []
    }

    private var usageBalances: [QuotaBalance] {
        usageSnapshot.balances
    }

    private var telemetryAccentColor: Color { accentColor }

    private var showsTelemetryDetails: Bool {
        disclosureStore.isExpanded(for: usageSnapshot.providerID)
    }

    private var latestUpdatedAt: Date {
        max(usageSnapshot.fetchedAt, telemetrySnapshot?.fetchedAt ?? usageSnapshot.fetchedAt)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            combinedHeader
            Divider().overlay(Color.white.opacity(0.10))
            combinedBody
        }
        .overlay(alignment: .topTrailing) {
            if hasTelemetryContent {
                telemetryToggleButton
                    .padding(.top, 8)
                    .padding(.trailing, 8)
            }
        }
        .glassCardBackground(accent: accentColor, cornerRadius: 16)
        .overlay {
            if isRefreshing {
                RefreshHaloOverlay(accentColor: accentColor, cornerRadius: 16)
            }
        }
    }

    private var combinedHeader: some View {
        HStack(spacing: 8) {
            ProviderBrandIconView(providerID: usageSnapshot.providerID, size: 24)

            VStack(alignment: .leading, spacing: 1) {
                ProviderCardTitleText(title: usageSnapshot.displayName, accentColor: accentColor)

                headerMetadataLine(plan: usageSnapshot.planName, updatedAt: latestUpdatedAt)
            }

            Spacer()

            fetchStateIndicator
        }
        .padding(10)
    }

    @ViewBuilder
    private var fetchStateIndicator: some View {
        switch usageSnapshot.fetchState {
        case .success:
            EmptyView()
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 16))
        case .notConfigured:
            Image(systemName: "gear")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
        }
    }

    private var combinedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !usageSnapshot.summaryWindows.isEmpty {
                VStack(spacing: 8) {
                    ForEach(usageSnapshot.summaryWindows) { window in
                        QuotaWindowRow(window: window, accentColor: accentColor, providerID: usageSnapshot.providerID)
                    }
                }
            }

            if showsTelemetryDetails {
                if !usageBalances.isEmpty {
                    supplementalSection(title: usageSnapshot.balancesSectionTitle ?? "Credits / Balance") {
                        SnapshotMetricListView(
                            items: usageBalances.map {
                                SnapshotMetricItem(
                                    id: $0.id,
                                    title: $0.label,
                                    value: $0.valueText,
                                    subtitle: $0.subtitle ?? $0.resetDate.map { "Resets \($0.countdownString)" }
                                )
                            },
                            accentColor: telemetryAccentColor
                        )
                    }
                }

                if !telemetrySignals.isEmpty {
                    supplementalSection(title: "Recent Changes") {
                        VStack(spacing: 6) {
                            ForEach(telemetrySignals.prefix(2)) { signal in
                                SnapshotSignalNotice(signal: signal, accentColor: telemetryAccentColor)
                            }
                        }
                    }
                }

                if let telemetrySnapshot, !telemetryRows.isEmpty {
                    supplementalSection(title: telemetrySnapshot.statsSectionTitle ?? "Telemetry") {
                        SnapshotMetricListView(
                            items: telemetryRows.map {
                                SnapshotMetricItem(
                                    id: $0.id,
                                    title: $0.label,
                                    value: $0.valueText,
                                    subtitle: $0.subtitle
                                )
                            },
                            accentColor: telemetryAccentColor
                        )
                    }
                }

                if let telemetrySnapshot, !telemetryBalances.isEmpty {
                    supplementalSection(title: telemetrySnapshot.balancesSectionTitle ?? "Telemetry Balance") {
                        SnapshotMetricListView(
                            items: telemetryBalances.map {
                                SnapshotMetricItem(
                                    id: $0.id,
                                    title: $0.label,
                                    value: $0.valueText,
                                    subtitle: $0.subtitle ?? $0.resetDate.map { "Resets \($0.countdownString)" }
                                )
                            },
                            accentColor: telemetryAccentColor
                        )
                    }
                }
            }
        }
        .padding(10)
    }

    private func supplementalSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            content()
        }
    }

    private var hasTelemetryContent: Bool {
        telemetrySnapshot?.hasContent == true || !usageSnapshot.balances.isEmpty
    }

    private var telemetryToggleButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                disclosureStore.toggle(usageSnapshot.providerID)
            }
        } label: {
            Image(systemName: "tablecells.fill.badge.ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(showsTelemetryDetails ? telemetryAccentColor : .white)
                .background(
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(telemetryAccentColor.opacity(0.28), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsTelemetryDetails ? "Hide telemetry details" : "Show telemetry details")
    }
}

private struct RefreshHaloOverlay: View {
    let accentColor: Color
    let cornerRadius: CGFloat
    @State private var isAnimating = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(colors: [
                        .clear,
                        accentColor.opacity(0.10),
                        accentColor.opacity(0.88),
                        .white.opacity(0.45),
                        accentColor.opacity(0.18),
                        .clear
                    ]),
                    center: .center,
                    angle: .degrees(360)
                ),
                lineWidth: 2
            )
            .blur(radius: 1.2)
            .blendMode(.screen)
            .shadow(color: accentColor.opacity(0.24), radius: 18, x: 0, y: 0)
            .opacity(isAnimating ? 0 : 1)
            .onAppear {
                withAnimation(.linear(duration: 2.0)) {
                    isAnimating = true
                }
            }
            .allowsHitTesting(false)
    }
}

public struct SnapshotMetricItem: Identifiable, Hashable {
    public let id: UUID
    public let title: String
    public let value: String
    public let subtitle: String?

    public init(
        id: UUID = UUID(),
        title: String,
        value: String,
        subtitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.subtitle = subtitle
    }
}

public struct SnapshotMetricListView: View {
    let items: [SnapshotMetricItem]
    let accentColor: Color

    public init(items: [SnapshotMetricItem], accentColor: Color) {
        self.items = items
        self.accentColor = accentColor
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                SnapshotMetricRow(item: item, accentColor: accentColor)

                if index < items.count - 1 {
                    Divider()
                        .overlay(Color.white.opacity(0.06))
                }
            }
        }
        .background(Color.white.opacity(0.032), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.065), lineWidth: 1)
        )
    }
}

public struct SnapshotMetricRow: View {
    let item: SnapshotMetricItem
    let accentColor: Color

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            Text(item.value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accentColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - Window Row

public struct QuotaWindowRow: View {
    let window: QuotaWindow
    let accentColor: Color
    let providerID: ProviderID?

    public init(window: QuotaWindow, accentColor: Color, providerID: ProviderID? = nil) {
        self.window = window
        self.accentColor = accentColor
        self.providerID = providerID
    }

    public var body: some View {
        let pace = window.pace(providerID: providerID)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(window.leadingValueText)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(usageColor(for: window.fractionUsed, accentColor: accentColor))
            }

            if window.hasExplicitLimit {
                QuotaProgressBar(
                    fraction: window.fractionUsed,
                    accentColor: accentColor,
                    pace: pace
                )
            }

            HStack {
                Text(window.measurementSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let pace, pace.shouldSurface {
                    PaceBadge(pace: pace)
                }
                if let resetDate = window.resetDate {
                    Text("Resets \(resetDate.countdownString)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

        }
    }
}

private struct PaceBadge: View {
    let pace: QuotaPace

    private var color: Color {
        Color(hex: pace.colorHex)
    }

    var body: some View {
        Text(pace.compactStatusText)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(color.opacity(0.18), lineWidth: 0.5)
            )
    }
}

struct SnapshotSignalNotice: View {
    let signal: QuotaSignal
    let accentColor: Color

    private var signalColor: Color {
        switch signal.severity {
        case .info:
            return accentColor
        case .warning:
            return .yellow
        case .critical:
            return .red
        }
    }

    private var iconName: String {
        switch signal.kind {
        case .unexpectedRecovery:
            return "sparkles.rectangle.stack"
        case .scheduledReset:
            return "arrow.clockwise.circle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(signalColor)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(signalColor.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(signal.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)

                    Text(signal.detectedAt.relativeString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(signal.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let confidenceText = signal.confidenceText {
                    Text(confidenceText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.065), lineWidth: 1)
        )
    }
}

// MARK: - Progress Bar

public struct QuotaProgressBar: View {
    let fraction: Double
    let accentColor: Color
    let pace: QuotaPace?
    var height: CGFloat = 8

    public init(fraction: Double, accentColor: Color, height: CGFloat = 8, pace: QuotaPace? = nil) {
        self.fraction = fraction
        self.accentColor = accentColor
        self.height = height
        self.pace = pace
    }

    public var body: some View {
        GeometryReader { geo in
            let clampedFraction = min(max(fraction, 0), 1)
            let fillColor = usageColor(for: clampedFraction, accentColor: accentColor)
            let fillWidth = geo.size.width * clampedFraction
            let markerWidth = max(2, height * 0.28)

            ZStack(alignment: .leading) {
                // Glass tube track
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(Color.white.opacity(0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.22),
                                        Color.white.opacity(0.05)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    )
                    .frame(height: height)

                if clampedFraction > 0 {
                    // Liquid fill with specular glass highlight
                    RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                        .fill(progressiveMeterGradient(fraction: clampedFraction, accentColor: accentColor))
                        .frame(width: fillWidth, height: height)
                        .shadow(color: fillColor.opacity(0.5), radius: 5, y: 0)
                        .overlay(alignment: .top) {
                            // Specular highlight — top ~45% of fill appears as glass refraction
                            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.58),
                                            Color.white.opacity(0.0)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: fillWidth, height: height * 0.46)
                        }
                }

                if let pace, pace.shouldSurface {
                    let markerX = min(
                        max((geo.size.width * pace.expectedFraction) - (markerWidth / 2), 0),
                        max(geo.size.width - markerWidth, 0)
                    )
                    Capsule(style: .continuous)
                        .fill(Color(hex: pace.colorHex).opacity(0.95))
                        .frame(width: markerWidth, height: height + 4)
                        .offset(x: markerX)
                        .shadow(color: Color(hex: pace.colorHex).opacity(0.55), radius: 3, y: 0)
                        .accessibilityLabel("Quota pace guide")
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Small Widget Card

/// Compact version for small widget family
public struct QuotaCardSmallView: View {
    let snapshot: QuotaSnapshot
    var style: AppChromeStyle = .panel

    public init(snapshot: QuotaSnapshot, style: AppChromeStyle = .panel) {
        self.snapshot = snapshot
        self.style = style
    }

    private var accent: Color { Color(hex: snapshot.providerID.accentColorHex) }
    private var windows: [QuotaWindow] { Array(snapshot.summaryWindows.prefix(4)) }

    public var body: some View {
        GlassCardContainer(style: style, accent: accent, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ProviderBrandIconView(providerID: snapshot.providerID, size: 14)
                    Text(snapshot.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                if !windows.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(windows) { window in
                            compactWindowView(window)
                        }
                    }
                } else {
                    Text("No data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func compactWindowView(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 3)

                if let resetText = compactResetText(for: window) {
                    Text(resetText)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Text(window.leadingValueText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(usageColor(for: window.fractionUsed, accentColor: accent))
                    .lineLimit(1)
                    .monospacedDigit()
            }

            if window.hasExplicitLimit {
                QuotaProgressBar(
                    fraction: window.fractionUsed,
                    accentColor: accent,
                    height: 3.5,
                    pace: window.pace(providerID: snapshot.providerID)
                )
            } else if compactResetText(for: window) == nil {
                Text(window.measurementSummary)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func compactResetText(for window: QuotaWindow) -> String? {
        guard let resetDate = window.resetDate else { return nil }
        let text = resetDate.countdownString
        return text.hasPrefix("in ") ? String(text.dropFirst(3)) : text
    }
}

// MARK: - Color + Date Helpers

public func usageColor(for fraction: Double, accentColor: Color) -> Color {
    switch fraction {
    case ..<0.6:
        return accentColor
    case ..<0.9:
        return Color(hex: "#F59E0B")
    default:
        return Color(hex: "#DC2626")
    }
}

fileprivate func progressiveMeterGradient(fraction: Double, accentColor: Color) -> LinearGradient {
    let orange = Color(hex: "#F59E0B")
    let red = Color(hex: "#DC2626")
    let clampedFraction = min(max(fraction, 0), 1)

    guard clampedFraction > 0.6 else {
        return LinearGradient(
            colors: [accentColor.opacity(0.98), accentColor],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    let orangeStart = min(1, 0.6 / clampedFraction)

    guard clampedFraction > 0.9 else {
        return LinearGradient(
            stops: [
                .init(color: accentColor.opacity(0.98), location: 0.0),
                .init(color: accentColor, location: orangeStart),
                .init(color: orange, location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    let redStart = min(1, 0.9 / clampedFraction)

    return LinearGradient(
        stops: [
            .init(color: accentColor.opacity(0.98), location: 0.0),
            .init(color: accentColor, location: orangeStart),
            .init(color: orange, location: redStart),
            .init(color: red, location: 1.0)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
}

extension Color {
    public init(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        let val = UInt64(hex, radix: 16) ?? 0
        let r = Double((val >> 16) & 0xFF) / 255
        let g = Double((val >> 8) & 0xFF) / 255
        let b = Double(val & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Previews

struct QuotaCardView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ScrollView {
                VStack(spacing: 16) {
                    QuotaCardView(snapshot: MockData.claudeSnapshot)
                    QuotaCardView(snapshot: MockData.codexSnapshot)
                    QuotaCardView(snapshot: MockData.cursorSnapshot)
                    QuotaCardView(snapshot: MockData.errorSnapshot)
                    QuotaCardView(snapshot: MockData.notConfiguredSnapshot)
                }
                .padding()
            }
            .background(Color(hex: "#0A0A0F"))

            QuotaCardSmallView(snapshot: MockData.claudeSnapshot)
                .frame(width: 155, height: 155)
        }
        .preferredColorScheme(.dark)
    }
}
