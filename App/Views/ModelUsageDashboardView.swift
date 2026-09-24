import SwiftUI
import Charts

/// Model-usage colours: TaskWraith's provider accents, and neutral where none applies.
private enum UsageColor {
    static let neutral = Color.white.opacity(0.55)

    static func provider(_ identity: String?) -> Color {
        guard let identity, let hex = TaskWraithProviderPalette.hex(for: identity) else { return neutral }
        return Color(hex: hex)
    }

    /// A source wears its provider's accent; TaskWraith's runs span providers.
    static func source(_ source: ModelUsageInsightSource) -> Color {
        provider(source.provider?.rawValue ?? source.id.split(separator: ":").first.map(String.init))
    }
}

struct ModelUsageDashboardView: View {
    @EnvironmentObject private var appState: AppStateStore
    @State private var selectedSource = ""
    @State private var selectedModel = ""
    @State private var window: ModelUsageWindow = .month
    @State private var showRates = false
    @State private var rateSearch = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let data = ModelUsageInsightData(archive: appState.modelUsage, snapshots: appState.snapshots)
            // Until one is picked, open on the source with the most tokens in the window.
            let source = data.sources.first { $0.id == selectedSource } ?? data.busiest(1, window: window, now: timeline.date).first?.source
            let sourceID = source?.id ?? ""
            let accent = source.map(UsageColor.source) ?? UsageColor.neutral
            let entries = data.selected(source: sourceID, model: selectedModel, window: window, now: timeline.date)
            let totals = ModelUsageInsightTotals(entries)
            let chartRows = data.chartRows(source: sourceID, model: selectedModel)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    header
                    if data.sources.isEmpty {
                        emptyState
                    } else {
                        controls(data: data, source: sourceID)
                        if let source {
                            StackCard(accent: accent) {
                                summary(source, totals: totals, models: Set(entries.filter { $0.tokens.total > 0 }.map(\.model)).count, accent: accent)
                                StackDivider()
                                tokenMix(totals, accent: accent)
                                StackDivider()
                                models(data, source: sourceID, now: timeline.date)
                                if let snapshot = appState.snapshots.first(where: { $0.providerID == source.provider }) {
                                    StackDivider()
                                    quota(snapshot)
                                }
                            }
                            StackCard(accent: accent) { windows(data, source: sourceID, now: timeline.date) }
                            StackCard(accent: accent) {
                                ModelUsageTokenChart(rows: chartRows, window: window, now: timeline.date)
                                StackDivider()
                                if source.local {
                                    ModelUsageActivityGrid(rows: chartRows, now: timeline.date)
                                } else {
                                    Text("Provider buckets · two-hour activity needs local logs").font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                StackDivider()
                                ModelUsageYearGrid(rows: chartRows, now: timeline.date)
                            }
                        }
                    }
                    StackCard(accent: .white) { rates }
                    Text("API equivalent is a hypothetical standard-rate cost, not billed. Each record is priced alone (\(ModelRateCatalog.version) rates); unknown splits or tiers show as ranges and unknown models stay unpriced.")
                        .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .help("A long-context tier applies only when one call's prompt reached it. Historical discounts, fast mode, tools and taxes may differ. Cache writes use the input rate; reasoning is included in output. No fallback rate is used.")
                }
                .padding(10)
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity)
            }
            .background(LiquidGlassBackdrop())
            .tint(accent)
        }
        .navigationTitle("Model usage")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { appState.refreshModelUsage() } label: {
                    Label("Refresh history", systemImage: "arrow.clockwise")
                }.disabled(appState.isIndexingModelUsage)
            }
        }
        .onChange(of: selectedSource) { _ in selectedModel = "" }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text("Model usage").font(.system(size: 13, weight: .bold))
                Spacer(minLength: 4)
                if appState.isIndexingModelUsage { ProgressView().controlSize(.mini) }
            }
            if let status = appState.modelUsageStatus {
                Text(status).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
            }
            if let error = appState.modelUsageSyncError {
                Label(error, systemImage: "icloud.slash").font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
    }

    private var emptyState: some View {
        StackCard(accent: .white) {
            StackSection(title: "No history yet", caption: "Collected on Mac · iCloud to iPhone") {
                Text("Connect Codex, Claude, Grok, Gemini or Kimi in Providers, or TaskWraith in Settings.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Button("Refresh") { appState.refreshModelUsage() }
                    .controlSize(.small).disabled(appState.isIndexingModelUsage)
            }
        }
    }

    private func controls(data: ModelUsageInsightData, source: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                sourceMenu(data: data, source: source)
                modelMenu(data: data, source: source)
                Spacer(minLength: 4)
                windowPicker
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    sourceMenu(data: data, source: source)
                    modelMenu(data: data, source: source)
                }
                windowPicker
            }
            VStack(alignment: .leading, spacing: 5) {
                sourceMenu(data: data, source: source)
                modelMenu(data: data, source: source)
                windowPicker
            }
        }
        .controlSize(.small)
        .help("One source at a time: local logs and API reports can describe the same requests, so sources are never added together.")
    }

    private var windowPicker: some View {
        Picker("Time window", selection: $window) {
            ForEach(ModelUsageWindow.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    private func sourceMenu(data: ModelUsageInsightData, source: String) -> some View {
        Picker("Source", selection: Binding(get: { source }, set: { selectedSource = $0 })) {
            ForEach(data.sources) { Text($0.title).tag($0.id) }
        }.pickerStyle(.menu).labelsHidden().fixedSize()
    }

    private func modelMenu(data: ModelUsageInsightData, source: String) -> some View {
        Picker("Model", selection: $selectedModel) {
            Text("All models").tag("")
            ForEach(Array(Set(data.entries.filter { $0.source == source && $0.tokens.total > 0 }.map(\.model))).sorted(), id: \.self) {
                Text($0).tag($0)
            }
        }.pickerStyle(.menu).labelsHidden().fixedSize()
    }

    private func summary(_ source: ModelUsageInsightSource, totals: ModelUsageInsightTotals, models: Int, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                SourceMark(provider: source.provider, accent: accent)
                Text(source.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(window.rawValue) · \(models) \(models == 1 ? "model" : "models")").font(stackCaption).foregroundStyle(.secondary).lineLimit(1)
            }
            let observed = [source.first, source.last].compactMap { $0?.formatted(date: .abbreviated, time: .omitted) }
            Text(([source.detail] + (observed.isEmpty ? [] : [observed.joined(separator: " – ")])).joined(separator: " · "))
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
            if let issue = source.issue { Text(issue).font(.system(size: 9)).foregroundStyle(.orange) }
            if totals.inferredTokens > 0 {
                StackRow(label: "Measured tokens", value: ModelUsageFormat.tokens(totals.measuredTokens))
                StackRow(label: "Estimated tokens", detail: "inferred, not reported", value: ModelUsageFormat.tokens(totals.inferredTokens))
            } else {
                StackRow(label: "Tokens", value: ModelUsageFormat.tokens(totals.tokens.total))
            }
            StackRow(label: "Requests", detail: totals.runs <= 0 || totals.runs >= totals.requests ? nil : "incl. \(ModelUsageFormat.tokens(totals.runs)) whole runs",
                     value: ModelUsageFormat.requests(totals.requests, runs: totals.runs))
            StackRow(label: "Cache hits", detail: "of prompt tokens", value: totals.cacheShare.formatted(.percent.precision(.fractionLength(1))))
            StackRow(label: "API equivalent", detail: estimateFootnote(totals), value: ModelUsageFormat.estimate(totals), valueColor: accent)
            if let cost = totals.actualUSD {
                StackRow(label: "Reported spend", detail: "billed by provider", value: ModelUsageFormat.money(cost))
            }
            if let cost = totals.reportedEstimateUSD {
                StackRow(label: "Card estimate", detail: "card's method · not billed", value: ModelUsageFormat.money(cost))
            }
        }
        .help("Blank cells mean no recorded usage, not proof of no activity.")
    }

    private func estimateFootnote(_ totals: ModelUsageInsightTotals) -> String {
        let percent = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))
        var text = "not billed · \(totals.coverage.formatted(percent)) exact"
        if totals.rangedTokens > 0 { text += " · \(totals.rangeCoverage.formatted(percent)) bounded" }
        return text
    }

    private func tokenMix(_ totals: ModelUsageInsightTotals, accent: Color) -> some View {
        let parts: [(String, Double, Color)] = [
            ("Fresh input", totals.tokens.input, accent), ("Cache read", totals.tokens.cacheRead, accent.opacity(0.55)),
            ("Cache write", totals.tokens.cacheWrite, accent.opacity(0.3)), ("Output", totals.tokens.output, Color.white.opacity(0.8))
        ] + (totals.tokens.unsplit > 0 ? [("Breakdown unavailable", totals.tokens.unsplit, Color.gray.opacity(0.45))] : [])
        return StackSection(title: "Token mix", caption: "\(window.rawValue) · reasoning within output") {
            GeometryReader { geometry in
                let shown = parts.filter { $0.1 > 0 }
                let gaps = CGFloat(2 * max(0, shown.count - 1))
                HStack(spacing: 2) {
                    ForEach(shown.indices, id: \.self) { index in
                        Rectangle().fill(shown[index].2)
                            .frame(width: max(1, (geometry.size.width - gaps) * shown[index].1 / max(1, totals.tokens.total)))
                    }
                }.clipShape(Capsule())
            }.frame(height: 4).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], alignment: .leading, spacing: 3) {
                ForEach(parts.indices, id: \.self) { index in
                    HStack(spacing: 5) {
                        Circle().fill(parts[index].2).frame(width: 6, height: 6)
                        Text(parts[index].0).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(ModelUsageFormat.tokens(parts[index].1)).font(.system(size: 10, weight: .bold)).monospacedDigit()
                    }
                }
            }
            if totals.tokens.reasoning > 0 || totals.tokens.unsplit > 0 {
                Text([totals.tokens.reasoning > 0 ? "\(ModelUsageFormat.tokens(totals.tokens.reasoning)) reasoning in output" : nil,
                      totals.tokens.unsplit > 0 ? "total-only records priced as a range" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func models(_ data: ModelUsageInsightData, source: String, now: Date) -> some View {
        let rows = data.selected(source: source, window: window, now: now)
        let groups = Dictionary(grouping: rows.filter { $0.tokens.total > 0 }, by: \.model)
            .map { (model: $0.key, total: ModelUsageInsightTotals($0.value)) }
            .sorted { $0.total.tokens.total > $1.total.tokens.total }
        let total = rows.reduce(0) { $0 + $1.tokens.total }
        return StackSection(title: "Models", caption: "\(window.rawValue) · share of source") {
            ForEach(groups, id: \.model) { item in
                let color = UsageColor.provider(ModelUsageDisplayIdentity.provider(model: item.model, source: source))
                let share = item.total.tokens.total / max(1, total)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text(item.model).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                        Spacer(minLength: 6)
                        Text(ModelUsageFormat.estimate(item.total)).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                        Text(ModelUsageFormat.tokens(item.total.tokens.total)).font(.system(size: 11, weight: .bold)).monospacedDigit()
                            .frame(minWidth: 42, alignment: .trailing)
                    }
                    StackBar(fraction: share, color: color)
                }
                .help("\(share.formatted(.percent.precision(.fractionLength(1)))) of source · \(ModelUsageFormat.tokens(item.total.tokens.prompt)) in incl. cache · \(ModelUsageFormat.tokens(item.total.tokens.output)) out · \(ModelUsageFormat.requests(item.total.requests, runs: item.total.runs))")
            }
            if groups.isEmpty { Text("No model tokens in this window").font(.system(size: 9)).foregroundStyle(.secondary) }
            DisclosureGroup("Compare sources") {
                ForEach(data.sources) { item in
                    let totals = ModelUsageInsightTotals(data.selected(source: item.id, window: window, now: now))
                    HStack(spacing: 8) {
                        SourceMark(provider: item.provider, accent: UsageColor.source(item))
                        Text(item.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(ModelUsageFormat.estimate(totals)).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                        Text(ModelUsageFormat.tokens(totals.tokens.total)).font(.system(size: 10, weight: .bold)).monospacedDigit()
                    }
                }
                Text("Sources can overlap and are never added together").font(.system(size: 9)).foregroundStyle(.secondary)
            }.font(.system(size: 10, weight: .semibold))
        }
    }

    private func quota(_ snapshot: QuotaSnapshot) -> some View {
        let color = UsageColor.provider(snapshot.providerID.rawValue)
        return StackSection(title: "Quota", caption: snapshot.displayName) {
            if snapshot.summaryWindows.isEmpty {
                Text("No quota windows reported").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            ForEach(snapshot.summaryWindows.prefix(4)) { quota in
                VStack(alignment: .leading, spacing: 3) {
                    StackRow(label: quota.label, detail: quota.resetDate.map { "Resets \($0.absoluteResetString)" }, value: quota.leadingValueText)
                    if quota.total != nil { StackBar(fraction: quota.fractionUsed, color: color) }
                }
            }
            if !snapshot.stats.isEmpty {
                DisclosureGroup("More telemetry (\(snapshot.stats.count))") {
                    ForEach(snapshot.stats) { stat in
                        StackRow(label: stat.label, value: "\(ModelUsageFormat.tokens(stat.value)) \(stat.unit)")
                    }
                }.font(.system(size: 10, weight: .semibold))
            }
        }
    }

    private func windows(_ data: ModelUsageInsightData, source: String, now: Date) -> some View {
        let byModel = Dictionary(grouping: data.entries.filter { $0.source == source && $0.tokens.total > 0 && $0.end > now.addingTimeInterval(-90 * 86400) }, by: \.model)
        let models = byModel.keys.sorted()
        return StackSection(title: "Windows", caption: "tokens · API equivalent") {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    GridRow {
                        Text("Model").frame(width: 140, alignment: .leading)
                        ForEach(ModelUsageWindow.allCases) { Text($0.rawValue).frame(width: 72, alignment: .trailing) }
                    }.font(stackCaption).foregroundStyle(.secondary)
                    ForEach(models, id: \.self) { model in
                        GridRow(alignment: .top) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(model).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                if model == "Unknown model" { Text("Unattributed").font(.system(size: 9)).foregroundStyle(.orange) }
                            }.frame(width: 140, alignment: .leading)
                            ForEach(ModelUsageWindow.allCases) { period in
                                let rows = (byModel[model] ?? []).filter { ModelUsageInsightData.contains($0, window: period, now: now) }
                                let totals = ModelUsageInsightTotals(rows)
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text(rows.isEmpty ? "—" : ModelUsageFormat.tokens(totals.tokens.total)).font(.system(size: 11, weight: .bold))
                                    Text(ModelUsageFormat.estimate(totals)).font(.system(size: 9)).foregroundStyle(.secondary)
                                }.monospacedDigit().frame(width: 72, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .help("Local windows have five-minute boundaries. Provider buckets wider than a window are omitted; a dash means unavailable. Estimates can be partial when models or request tiers are unknown.")
        }
    }

    private var rates: some View {
        StackSection(title: "Rates", caption: "\(ModelRateCatalog.rates.count) rows · \(ModelRateCatalog.version)") {
            DisclosureGroup("API rates & context windows", isExpanded: $showRates) {
                TextField("Search model or provider", text: $rateSearch).textFieldStyle(.roundedBorder).controlSize(.small).padding(.vertical, 4)
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(ModelRateCatalog.rates.filter { rateSearch.isEmpty || $0.id.localizedCaseInsensitiveContains(rateSearch) }) { rate in
                        DisclosureGroup {
                            Text(rate.notes ?? "Standard API rate from the imported catalog.").font(.system(size: 10)).foregroundStyle(.secondary)
                            if let threshold = rate.threshold {
                                Text("Prompt ≥ \(ModelUsageFormat.tokens(threshold)): input \(ModelUsageFormat.rate(rate.longInput)), cached \(ModelUsageFormat.rate(rate.longCached)), output \(ModelUsageFormat.rate(rate.longOutput)) per million. Every token uses the long-context tier.")
                                    .font(.system(size: 10)).foregroundStyle(.orange)
                            }
                            if let url = URL(string: rate.url), url.scheme == "https" {
                                Link("Pricing source", destination: url).font(.system(size: 10)).padding(.top, 2)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Circle().fill(UsageColor.provider(rate.provider)).frame(width: 6, height: 6)
                                    Text(rate.model).font(.system(size: 11, weight: .semibold))
                                }
                                Text("\(rate.provider.capitalized) · \(rate.isLocalInference ? "Local inference" : rate.status.title) · \(rate.context.map { ModelUsageFormat.tokens(Double($0)) + " context" } ?? "context not listed")")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                                if rate.status == .estimated && !rate.isLocalInference {
                                    Text("In \(ModelUsageFormat.rate(rate.input))  ·  Cache \(ModelUsageFormat.rate(rate.cached))  ·  Out \(ModelUsageFormat.rate(rate.output)) / 1M")
                                        .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                }
            }.font(.system(size: 10, weight: .semibold))
        }
    }
}

private let stackCaption = Font.system(size: 9, weight: .semibold, design: .rounded)

/// The quota stacks' card: sections 14 pt apart on one glass card.
private struct StackCard<Content: View>: View {
    let accent: Color
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCardBackground(accent: accent, cornerRadius: 16)
    }
}

private struct StackDivider: View {
    var body: some View { Divider().overlay(Color.white.opacity(0.08)) }
}

/// A stack section header: bold 13 pt title with a small caption on the right.
private struct StackSection<Content: View>: View {
    let title: String
    let caption: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(caption).font(stackCaption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }.padding(.bottom, 1)
            content
        }
    }
}

/// A meter-row line: label, optional detail and a bold trailing value.
private struct StackRow: View {
    let label: String
    var detail: String? = nil
    let value: String
    var valueColor: Color = .primary
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            if let detail { Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1) }
            Text(value).font(.system(size: 11, weight: .bold)).foregroundStyle(valueColor).monospacedDigit().lineLimit(1)
        }
    }
}

/// The meters' 4 pt bar.
private struct StackBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color.gradient).frame(width: geometry.size.width * min(1, max(0, fraction.isFinite ? fraction : 0)))
            }
        }.frame(height: 4).accessibilityHidden(true)
    }
}

/// A provider's brand mark, or a dot in the source's accent when it spans providers.
private struct SourceMark: View {
    let provider: ProviderID?
    let accent: Color
    var body: some View {
        Group {
            if let provider { ProviderBrandIconView(providerID: provider, size: 13) }
            else { Circle().fill(accent).frame(width: 7, height: 7) }
        }.frame(width: 16, height: 16)
    }
}

private struct ModelUsageTokenChart: View {
    let rows: [ModelUsageRollup]
    let window: ModelUsageWindow
    let now: Date
    @State private var selectedDate: Date?

    private var samples: [ModelUsageDay] {
        if window == .hour || window == .day {
            let interval: Double = window == .hour ? 300 : 3600
            let last = floor(now.timeIntervalSince1970 / interval) * interval
            let count = window == .hour ? 12 : 24
            var grouped: [Double: ModelUsageDay] = [:]
            for row in rows where row.seconds <= Int(interval) && row.start <= now {
                let key = floor(row.start.timeIntervalSince1970 / interval) * interval
                var point = grouped[key] ?? ModelUsageDay(date: Date(timeIntervalSince1970: key))
                point.tokens += row.tokens.total; point.requests += row.requests; point.runs += row.runs; grouped[key] = point
            }
            return (0..<count).reversed().map { offset in
                let key = last - Double(offset) * interval
                return grouped[key] ?? ModelUsageDay(date: Date(timeIntervalSince1970: key))
            }
        }
        return ModelUsageCalendar.days(rows, count: window == .week ? 7 : window == .month ? 30 : 90, now: now)
    }

    var body: some View {
        let points = samples
        let vendors = Dictionary(grouping: rows, by: { row -> Date in
            if window == .hour || window == .day {
                let interval: Double = window == .hour ? 300 : 3600
                return Date(timeIntervalSince1970: floor(row.start.timeIntervalSince1970 / interval) * interval)
            }
            return Calendar.current.startOfDay(for: row.start)
        }).compactMapValues { ModelUsageDisplayIdentity.dominant(in: $0) }
        let selected = selectedDate.flatMap { date in points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }
        StackSection(title: "Volume", caption: "\(window.rawValue) · drag to inspect") {
            Chart(points) { point in
                BarMark(x: .value("Date", point.date), y: .value("Tokens", point.tokens))
                    .foregroundStyle(UsageColor.provider(vendors[point.date]).gradient)
                    .cornerRadius(2)
                if let selected, selected.id == point.id {
                    RuleMark(x: .value("Selected", point.date)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartXAxis { AxisMarks { _ in AxisGridLine(); AxisValueLabel().font(.system(size: 8)) } }
            .chartYAxis { AxisMarks(position: .leading) { value in AxisGridLine(); AxisValueLabel { if let number = value.as(Double.self) { Text(ModelUsageFormat.tokens(number)).font(.system(size: 8)) } } } }
            .frame(height: 96)
            HStack {
                if let selected {
                    Text(selected.date.formatted(date: .abbreviated, time: window == .hour || window == .day ? .shortened : .omitted))
                    Spacer()
                    Text("\(ModelUsageFormat.tokens(selected.tokens)) tokens · \(ModelUsageFormat.requests(Double(selected.requests), runs: Double(selected.runs)))").monospacedDigit()
                } else {
                    Text("Peak \(ModelUsageFormat.tokens(points.map(\.tokens).max() ?? 0))")
                    Spacer()
                    Text("\(points.filter { $0.tokens > 0 }.count) active intervals")
                }
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

private let heatCell: CGFloat = 11

private struct ModelUsageActivityGrid: View {
    let rows: [ModelUsageRollup]
    let now: Date
    @State private var selected: String?
    private let calendar = Calendar.current

    var body: some View {
        let days = ModelUsageCalendar.days(rows, count: 90, now: now)
        let grouped = Dictionary(grouping: rows.filter { $0.start <= now && $0.start >= days[0].date }, by: { "\(calendar.startOfDay(for: $0.start).timeIntervalSince1970)|\(ModelUsageCalendar.twoHourIndex($0.start))" })
        let cells = grouped.mapValues { $0.reduce(0) { $0 + $1.tokens.total } }
        let vendors = grouped.compactMapValues { ModelUsageDisplayIdentity.dominant(in: $0) }
        let maxTokens = max(1, cells.values.max() ?? 1)
        StackSection(title: "Activity", caption: "90 days · 2h cells · \(calendar.timeZone.abbreviation() ?? "local")") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 4) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(" ").font(.system(size: 7)).frame(height: 10)
                        ForEach(0..<12) { hour in
                            Text(hour.isMultiple(of: 2) ? String(format: "%02d", hour * 2) : " ").font(.system(size: 7).monospacedDigit())
                                .foregroundStyle(.tertiary).frame(height: heatCell)
                        }
                    }
                    HStack(alignment: .top, spacing: 2) {
                        ForEach(days) { day in
                            VStack(spacing: 2) {
                                Text(calendar.component(.day, from: day.date) == 1 ? day.date.formatted(.dateTime.month(.abbreviated)) : " ")
                                    .font(.system(size: 7)).foregroundStyle(.tertiary).fixedSize().frame(width: heatCell, height: 10, alignment: .leading)
                                ForEach(0..<12) { hour in
                                    let key = "\(day.date.timeIntervalSince1970)|\(hour)"
                                    let value = cells[key] ?? 0
                                    Button { selected = "\(day.date.formatted(date: .abbreviated, time: .omitted)) · \(String(format: "%02d–%02d", hour * 2, hour * 2 + 2))h · \(ModelUsageFormat.tokens(value)) tokens" } label: {
                                        RoundedRectangle(cornerRadius: 2).fill(heatColor(value, maximum: maxTokens, vendor: vendors[key]))
                                            .frame(width: heatCell, height: heatCell)
                                    }.buttonStyle(.plain)
                                    .accessibilityLabel("\(day.date.formatted(date: .complete, time: .omitted)), \(hour * 2) to \(hour * 2 + 2) hours, \(ModelUsageFormat.tokens(value)) tokens")
                                    .help("\(day.date.formatted(date: .abbreviated, time: .omitted)) · \(hour * 2)h · \(ModelUsageFormat.tokens(value)) tokens")
                                }
                            }
                        }
                    }
                }
            }.defaultScrollAnchor(.trailing)
            if let selected { Text(selected).font(.system(size: 9)).foregroundStyle(.secondary) }
            heatLegend(rows)
        }
    }
}

private struct ModelUsageYearGrid: View {
    let rows: [ModelUsageRollup]
    let now: Date
    @State private var selected: ModelUsageDay?

    var body: some View {
        let calendar = Calendar.current
        let days = ModelUsageCalendar.days(rows, count: 365, now: now)
        let leading = days.first.map { (calendar.component(.weekday, from: $0.date) + 5) % 7 } ?? 0
        let slots: [ModelUsageDay?] = Array(repeating: nil, count: leading) + days.map { Optional($0) }
        let weeks = (slots.count + 6) / 7
        let maximum = max(1, days.map(\.tokens).max() ?? 1)
        let vendors = Dictionary(grouping: rows, by: { calendar.startOfDay(for: $0.start) })
            .compactMapValues { ModelUsageDisplayIdentity.dominant(in: $0) }
        let streaks = ModelUsageCalendar.streaks(days)
        let active = days.filter { $0.tokens > 0 }
        StackSection(title: "Year", caption: "365 days · Mon–Sun") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 4) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(" ").font(.system(size: 7)).frame(height: 10)
                        ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { index in
                            Text(index.isMultiple(of: 2) ? ["M", "T", "W", "T", "F", "S", "S"][index] : " ").font(.system(size: 7))
                                .foregroundStyle(.tertiary).frame(height: heatCell)
                        }
                    }
                    HStack(alignment: .top, spacing: 2) {
                        ForEach(0..<weeks, id: \.self) { week in
                            VStack(spacing: 2) {
                                let monthDay = (0..<7).compactMap { day -> ModelUsageDay? in let index = week * 7 + day; return index < slots.count ? slots[index] : nil }.first { calendar.component(.day, from: $0.date) <= 7 }
                                Text(monthDay?.date.formatted(.dateTime.month(.abbreviated)) ?? " ").font(.system(size: 7)).foregroundStyle(.tertiary)
                                    .fixedSize().frame(width: heatCell, height: 10, alignment: .leading)
                                ForEach(0..<7, id: \.self) { day in
                                    let index = week * 7 + day
                                    if index < slots.count, let value = slots[index] {
                                        Button { selected = value } label: {
                                            RoundedRectangle(cornerRadius: 2).fill(heatColor(value.tokens, maximum: maximum, vendor: vendors[value.date]))
                                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(selected?.date == value.date ? .white : .clear, lineWidth: 1))
                                                .frame(width: heatCell, height: heatCell)
                                        }.buttonStyle(.plain)
                                        .accessibilityLabel("\(value.date.formatted(date: .complete, time: .omitted)), \(ModelUsageFormat.tokens(value.tokens)) tokens, \(ModelUsageFormat.requests(Double(value.requests), runs: Double(value.runs)))")
                                        .help("\(value.date.formatted(date: .abbreviated, time: .omitted)): \(ModelUsageFormat.tokens(value.tokens)) tokens")
                                    } else { Color.clear.frame(width: heatCell, height: heatCell) }
                                }
                            }
                        }
                    }
                }
            }.defaultScrollAnchor(.trailing)
            if let selected {
                Text("\(selected.date.formatted(date: .complete, time: .omitted)) · \(ModelUsageFormat.tokens(selected.tokens)) tokens · \(ModelUsageFormat.requests(Double(selected.requests), runs: Double(selected.runs)))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            StackRow(label: "Active days", detail: "streak \(streaks.current)d · longest \(streaks.longest)d", value: "\(active.count)")
            StackRow(label: "Per active day", detail: active.max(by: { $0.tokens < $1.tokens }).map {
                "busiest \($0.date.formatted(date: .abbreviated, time: .omitted)) · \(ModelUsageFormat.tokens($0.tokens))"
            }, value: ModelUsageFormat.tokens(active.reduce(0) { $0 + $1.tokens } / Double(max(1, active.count))))
            heatLegend(rows)
        }
    }
}

private func heatColor(_ value: Double, maximum: Double, vendor: String? = nil) -> Color {
    guard value > 0 else { return Color.white.opacity(0.045) }
    let ratio = log1p(value) / log1p(max(1, maximum))
    return UsageColor.provider(vendor).opacity(0.15 + 0.85 * ratio)
}

/// Intensity scale plus the routed vendors whose TaskWraith hues colour the cells.
private func heatLegend(_ rows: [ModelUsageRollup]) -> some View {
    let vendors = Array(Set(rows.map { ModelUsageDisplayIdentity.provider(model: $0.model, source: $0.source) })).sorted()
    return HStack(spacing: 8) {
        HStack(spacing: 2) {
            Text("Less")
            ForEach(0..<5) { index in
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(index == 0 ? 0.045 : 0.15 + 0.2 * Double(index))).frame(width: 7, height: 7)
            }
            Text("More")
        }
        Spacer(minLength: 4)
        ForEach(vendors.prefix(6), id: \.self) { vendor in
            HStack(spacing: 3) {
                Circle().fill(UsageColor.provider(vendor)).frame(width: 6, height: 6)
                Text(ProviderID(rawValue: vendor)?.displayName ?? vendor.capitalized).lineLimit(1)
            }
        }
    }
    .font(.system(size: 8)).foregroundStyle(.secondary)
    .help("Logarithmic scale. Hue: the dominant routed vendor by tokens, in TaskWraith's provider colours; unknown or unprefixed models use the host's hue.")
    .accessibilityElement(children: .combine)
}

/// Dense preview for the menu popover and tall dashboard. The detailed page owns exploration.
struct ModelUsageSummaryCard: View {
    @EnvironmentObject private var appState: AppStateStore
    var action: () -> Void

    var body: some View {
        // Only the last day is shown, so only the last day's records are built on each redraw.
        let now = Date()
        let data = ModelUsageInsightData(archive: appState.modelUsage, snapshots: appState.snapshots, since: now.addingTimeInterval(-ModelUsageWindow.day.seconds))
        let ranked = data.busiest(3, window: .day, now: now)
        // The whole card opens the page: a banner can cover its header.
        Button(action: action) {
            GlassCardContainer(style: .panel, accent: ranked.first.map { UsageColor.source($0.source) } ?? .white, cornerRadius: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Model usage").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            Text("24H · tokens · API equivalent, not billed").font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if appState.isIndexingModelUsage { ProgressView().controlSize(.mini) }
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    if data.sources.isEmpty {
                        Text(appState.isIndexingModelUsage ? "Indexing history…" : "No history yet").font(.system(size: 9)).foregroundStyle(.secondary)
                    } else {
                        ForEach(ranked, id: \.source.id) { source, totals in
                            HStack(spacing: 8) {
                                SourceMark(provider: source.provider, accent: UsageColor.source(source))
                                Text(source.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(ModelUsageFormat.tokens(totals.tokens.total)).font(.system(size: 11, weight: .bold)).monospacedDigit()
                                Text(ModelUsageFormat.estimate(totals)).font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens model history and heatmaps")
    }
}
