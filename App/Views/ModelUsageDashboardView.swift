import SwiftUI
import Charts

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
            let source = data.sources.first { $0.id == selectedSource } ?? data.sources.first
            let sourceID = source?.id ?? ""
            let entries = data.selected(source: sourceID, model: selectedModel, window: window, now: timeline.date)
            let totals = ModelUsageInsightTotals(entries)
            let chartRows = data.chartRows(source: sourceID, model: selectedModel)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    header
                    if data.sources.isEmpty {
                        emptyState
                    } else {
                        sourcePicker(data: data, source: sourceID)
                        if let source {
                            coverage(source)
                            headline(totals, models: Set(entries.filter { $0.tokens.total > 0 }.map(\.model)).count)
                            tokenMix(totals)
                            if let snapshot = appState.snapshots.first(where: { $0.providerID == source.provider }) {
                                quotaPanel(snapshot)
                            }
                            windowTable(data, source: sourceID, now: timeline.date)
                            ModelUsageTokenChart(rows: chartRows, window: window, now: timeline.date)
                            if source.local {
                                ModelUsageActivityGrid(rows: chartRows, now: timeline.date)
                            } else {
                                Text("Provider buckets · two-hour activity needs local logs").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            ModelUsageYearGrid(rows: chartRows, now: timeline.date)
                            comparisons(data, source: sourceID, now: timeline.date)
                        }
                    }
                    rateReference
                    Text("API equivalent is a hypothetical standard-rate cost, not billed. Each record is priced alone (\(ModelRateCatalog.version) rates); unknown splits or tiers show as ranges and unknown models stay unpriced.")
                        .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .help("A long-context tier applies only when one call's prompt reached it. Historical discounts, fast mode, tools and taxes may differ. Cache writes use the input rate; reasoning is included in output. No fallback rate is used.")
                }
                .padding(12)
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity)
            }
            .background(LiquidGlassBackdrop())
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
        VStack(alignment: .leading, spacing: 2) {
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
        AnalyticsPanel(title: "No history yet", subtitle: "Collected on Mac · iCloud to iPhone") {
            Text("Connect Codex, Claude, Grok, Gemini or Kimi in Providers, or TaskWraith in Settings.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Refresh") { appState.refreshModelUsage() }
                .controlSize(.small).disabled(appState.isIndexingModelUsage)
        }
    }

    private func sourcePicker(data: ModelUsageInsightData, source: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    sourceMenu(data: data, source: source)
                    modelMenu(data: data, source: source)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    sourceMenu(data: data, source: source)
                    modelMenu(data: data, source: source)
                }
            }
            Picker("Time window", selection: $window) {
                ForEach(ModelUsageWindow.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
        }
        .controlSize(.small)
        .help("One source at a time: local logs and API reports can describe the same requests, so sources are never added together.")
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

    private func coverage(_ source: ModelUsageInsightSource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(source.provider.map { Color(hex: $0.accentColorHex) } ?? ProGlassTheme.accent).frame(width: 6, height: 6)
                Text(source.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let date = source.scanned { Text(date, style: .relative).font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            let observed = [source.first, source.last].compactMap { $0?.formatted(date: .abbreviated, time: .omitted) }
            Text(([source.detail] + (observed.isEmpty ? [] : [observed.joined(separator: " – ")])).joined(separator: " · "))
                .font(.system(size: 9)).foregroundStyle(.secondary)
            if let issue = source.issue { Text(issue).font(.system(size: 9)).foregroundStyle(.orange) }
        }
        .help("Blank cells mean no recorded usage, not proof of no activity.")
    }

    private func headline(_ totals: ModelUsageInsightTotals, models: Int) -> some View {
        GlassCardContainer(style: .panel, accent: ProGlassTheme.accent, cornerRadius: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10, alignment: .topLeading)], alignment: .leading, spacing: 10) {
                if totals.inferredTokens > 0 {
                    AnalyticsStat(title: "Measured tokens", value: ModelUsageFormat.tokens(totals.measuredTokens), note: "\(window.rawValue) · \(models) models")
                    AnalyticsStat(title: "Estimated tokens", value: ModelUsageFormat.tokens(totals.inferredTokens), note: "Inferred, not reported")
                } else {
                    AnalyticsStat(title: "Tokens", value: ModelUsageFormat.tokens(totals.tokens.total), note: "\(window.rawValue) · \(models) models")
                }
                AnalyticsStat(title: "Requests", value: ModelUsageFormat.tokens(totals.requests), note: totals.runs <= 0 ? "Calls"
                    : totals.runs >= totals.requests ? "Whole runs · calls unknown" : "Incl. \(ModelUsageFormat.tokens(totals.runs)) whole runs")
                AnalyticsStat(title: "Cache hits", value: totals.cacheShare.formatted(.percent.precision(.fractionLength(1))), note: "Of prompt tokens")
                AnalyticsStat(title: "API equivalent", value: ModelUsageFormat.estimate(totals), note: estimateFootnote(totals))
                if let cost = totals.actualUSD {
                    AnalyticsStat(title: "Reported spend", value: ModelUsageFormat.money(cost), note: "Billed by provider")
                }
                if let cost = totals.reportedEstimateUSD {
                    AnalyticsStat(title: "Card estimate", value: ModelUsageFormat.money(cost), note: "Card's method · not billed")
                }
            }.padding(4)
        }
    }

    private func estimateFootnote(_ totals: ModelUsageInsightTotals) -> String {
        let percent = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))
        var text = "Not billed · \(totals.coverage.formatted(percent)) exact"
        if totals.rangedTokens > 0 { text += " · \(totals.rangeCoverage.formatted(percent)) bounded" }
        return text
    }

    private func tokenMix(_ totals: ModelUsageInsightTotals) -> some View {
        AnalyticsPanel(title: "Token mix", subtitle: "\(window.rawValue) · reasoning within output") {
            let components: [(String, Double, Color)] = [
                ("Fresh input", totals.tokens.input, ProGlassTheme.accent), ("Cache read", totals.tokens.cacheRead, Color(hex: "#5E5CE6")),
                ("Cache write", totals.tokens.cacheWrite, .orange), ("Output", totals.tokens.output, Color(hex: "#30D158"))
            ] + (totals.tokens.unsplit > 0 ? [("Breakdown unavailable", totals.tokens.unsplit, .gray)] : [])
            GeometryReader { geometry in
                let gaps = CGFloat(2 * max(0, components.filter { $0.1 > 0 }.count - 1))
                HStack(spacing: 2) {
                    ForEach(components.indices, id: \.self) { index in
                        let item = components[index]
                        if item.1 > 0 {
                            Rectangle().fill(item.2.gradient)
                                .frame(width: max(1, (geometry.size.width - gaps) * item.1 / max(1, totals.tokens.total)))
                        }
                    }
                }.clipShape(Capsule())
            }.frame(height: 8).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 5) {
                ForEach(components.indices, id: \.self) { index in
                    let item = components[index]
                    HStack(spacing: 5) {
                        Circle().fill(item.2).frame(width: 6, height: 6)
                        Text(item.0).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(ModelUsageFormat.tokens(item.1)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
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

    private func quotaPanel(_ snapshot: QuotaSnapshot) -> some View {
        AnalyticsPanel(title: "Quota", subtitle: snapshot.displayName) {
            if snapshot.summaryWindows.isEmpty {
                Text("No quota windows reported").font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.summaryWindows.prefix(4)) { quota in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(quota.label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            if let reset = quota.resetDate {
                                Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Text(quota.leadingValueText).font(.system(size: 11, weight: .bold)).monospacedDigit()
                        }
                        if quota.total != nil {
                            ProgressView(value: min(1, max(0, quota.fractionUsed))).tint(Color(hex: snapshot.providerID.accentColorHex)).controlSize(.mini)
                        }
                    }
                }
            }
            if !snapshot.stats.isEmpty {
                DisclosureGroup("More telemetry (\(snapshot.stats.count))") {
                    ForEach(snapshot.stats) { stat in
                        HStack {
                            Text(stat.label)
                            Spacer()
                            Text("\(ModelUsageFormat.tokens(stat.value)) \(stat.unit)").monospacedDigit()
                        }.font(.system(size: 10)).padding(.vertical, 1)
                    }
                }.font(.system(size: 10, weight: .semibold))
            }
        }
    }

    private func windowTable(_ data: ModelUsageInsightData, source: String, now: Date) -> some View {
        let models = Array(Set(data.entries.filter { $0.source == source && $0.tokens.total > 0 && $0.end > now.addingTimeInterval(-90 * 86400) }.map(\.model))).sorted()
        return AnalyticsPanel(title: "Windows", subtitle: "Tokens · API equivalent") {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    GridRow {
                        Text("Model").frame(width: 150, alignment: .leading)
                        ForEach(ModelUsageWindow.allCases) { Text($0.rawValue).frame(width: 78, alignment: .trailing) }
                    }.font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    ForEach(models, id: \.self) { model in
                        GridRow(alignment: .top) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                                if model == "Unknown model" { Text("Unattributed").font(.system(size: 9)).foregroundStyle(.orange) }
                            }.frame(width: 150, alignment: .leading)
                            ForEach(ModelUsageWindow.allCases) { period in
                                let rows = data.selected(source: source, model: model, window: period, now: now)
                                let totals = ModelUsageInsightTotals(rows)
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(rows.isEmpty ? "—" : ModelUsageFormat.tokens(totals.tokens.total)).font(.system(size: 11, weight: .semibold))
                                    Text(ModelUsageFormat.estimate(totals)).font(.system(size: 9)).foregroundStyle(.secondary)
                                }.monospacedDigit().frame(width: 78, alignment: .trailing)
                            }
                        }
                    }
                }.padding(.vertical, 2)
            }
            .help("Local windows have five-minute boundaries. Provider buckets wider than a window are omitted; a dash means unavailable. Estimates can be partial when models or request tiers are unknown.")
        }
    }

    private func comparisons(_ data: ModelUsageInsightData, source: String, now: Date) -> some View {
        let rows = data.selected(source: source, window: window, now: now)
        let groups = Dictionary(grouping: rows.filter { $0.tokens.total > 0 }, by: \.model)
            .map { (model: $0.key, total: ModelUsageInsightTotals($0.value)) }
            .sorted { $0.total.tokens.total > $1.total.tokens.total }
        let total = rows.reduce(0) { $0 + $1.tokens.total }
        return AnalyticsPanel(title: "Models", subtitle: "\(window.rawValue) · share of source") {
            ForEach(groups, id: \.model) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.model).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(ModelUsageFormat.tokens(item.total.tokens.total)).font(.system(size: 11, weight: .bold)).monospacedDigit()
                        Text((item.total.tokens.total / max(1, total)).formatted(.percent.precision(.fractionLength(1))))
                            .font(.system(size: 9, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 34, alignment: .trailing)
                    }
                    ProgressView(value: item.total.tokens.total / max(1, total)).tint(ProGlassTheme.accent).controlSize(.mini)
                    Text("\(ModelUsageFormat.tokens(item.total.tokens.prompt)) in incl. cache · \(ModelUsageFormat.tokens(item.total.tokens.output)) out · \(ModelUsageFormat.requests(item.total.requests, runs: item.total.runs)) · \(ModelUsageFormat.estimate(item.total))")
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.vertical, 1)
            }
            if groups.isEmpty { Text("No model tokens in this window").font(.system(size: 9)).foregroundStyle(.secondary) }
            DisclosureGroup("Compare sources") {
                ForEach(data.sources) { item in
                    let totals = ModelUsageInsightTotals(data.selected(source: item.id, window: window, now: now))
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(ModelUsageFormat.tokens(totals.tokens.total)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        Text(ModelUsageFormat.estimate(totals)).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                    }.padding(.vertical, 1)
                }
                Text("Sources can overlap and are never added together").font(.system(size: 9)).foregroundStyle(.secondary)
            }.font(.system(size: 10, weight: .semibold)).padding(.top, 2)
        }
    }

    private var rateReference: some View {
        AnalyticsPanel(title: "Rates", subtitle: "\(ModelRateCatalog.rates.count) rows · \(ModelRateCatalog.version)") {
            DisclosureGroup("API rates & context windows", isExpanded: $showRates) {
                TextField("Search model or provider", text: $rateSearch).textFieldStyle(.roundedBorder).controlSize(.small).padding(.vertical, 4)
                LazyVStack(alignment: .leading, spacing: 6) {
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
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rate.model).font(.system(size: 11, weight: .semibold))
                                Text("\(rate.provider.capitalized) · \(rate.isLocalInference ? "Local inference" : rate.status.title) · \(rate.context.map { ModelUsageFormat.tokens(Double($0)) + " context" } ?? "context not listed")")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if rate.status == .estimated && !rate.isLocalInference {
                                    Text("In \(ModelUsageFormat.rate(rate.input))  ·  Cache \(ModelUsageFormat.rate(rate.cached))  ·  Out \(ModelUsageFormat.rate(rate.output)) / 1M")
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Divider()
                    }
                }
            }.font(.system(size: 10, weight: .semibold))
        }
    }
}

/// The quota stacks' card: bold 13 pt title, a small caption on the right, dense content.
private struct AnalyticsPanel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        GlassCardContainer(style: .panel, accent: ProGlassTheme.accent, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .bold))
                    Spacer(minLength: 4)
                    Text(subtitle).font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
                }
                content
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AnalyticsStat: View {
    let title: String
    let value: String
    let note: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(note).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
        AnalyticsPanel(title: "Volume", subtitle: "\(window.rawValue) · drag to inspect") {
            Chart(points) { point in
                BarMark(x: .value("Date", point.date), y: .value("Tokens", point.tokens))
                    .foregroundStyle(displayColor(vendors[point.date]).gradient)
                    .cornerRadius(2)
                if let selected, selected.id == point.id {
                    RuleMark(x: .value("Selected", point.date)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartYAxis { AxisMarks(position: .leading) { value in AxisGridLine(); AxisValueLabel { if let number = value.as(Double.self) { Text(ModelUsageFormat.tokens(number)) } } } }
            .frame(height: 140)
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
        AnalyticsPanel(title: "Activity", subtitle: "90 days · 2h cells · \(calendar.timeZone.abbreviation() ?? "local")") {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    VStack(spacing: 3) {
                        Text(" ").font(.caption2).frame(height: 18)
                        ForEach(0..<12) { hour in Text(String(format: "%02d", hour * 2)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, height: 20) }
                    }
                    HStack(alignment: .top, spacing: 3) {
                        ForEach(days) { day in
                            VStack(spacing: 3) {
                                Text(calendar.component(.day, from: day.date) == 1 ? day.date.formatted(.dateTime.month(.abbreviated)) : " ")
                                    .font(.system(size: 8)).frame(width: 20, height: 18)
                                ForEach(0..<12) { hour in
                                    let key = "\(day.date.timeIntervalSince1970)|\(hour)"
                                    let value = cells[key] ?? 0
                                    Button { selected = "\(day.date.formatted(date: .abbreviated, time: .omitted)) · \(String(format: "%02d–%02d", hour * 2, hour * 2 + 2))h · \(ModelUsageFormat.tokens(value)) tokens" } label: {
                                        RoundedRectangle(cornerRadius: 3).fill(heatColor(value, maximum: maxTokens, vendor: vendors[key]))
                                            .frame(width: 20, height: 20)
                                    }.buttonStyle(.plain)
                                    .accessibilityLabel("\(day.date.formatted(date: .complete, time: .omitted)), \(hour * 2) to \(hour * 2 + 2) hours, \(ModelUsageFormat.tokens(value)) tokens")
                                    .help("\(day.date.formatted(date: .abbreviated, time: .omitted)) · \(hour * 2)h · \(ModelUsageFormat.tokens(value)) tokens")
                                }
                            }
                        }
                    }
                }.padding(.vertical, 4)
            }.defaultScrollAnchor(.trailing)
            if let selected { Text(selected).font(.system(size: 9)).foregroundStyle(.secondary) }
            heatLegend
            routedVendorLegend(rows)
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
        AnalyticsPanel(title: "Year", subtitle: "365 days · Mon–Sun") {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 5) {
                    VStack(spacing: 4) {
                        Text(" ").frame(height: 18)
                        ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { index in
                            Text(["M", "T", "W", "T", "F", "S", "S"][index]).font(.caption2).foregroundStyle(.secondary).frame(width: 20, height: 28)
                        }
                    }
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(0..<weeks, id: \.self) { week in
                            VStack(spacing: 4) {
                                let monthDay = (0..<7).compactMap { day -> ModelUsageDay? in let index = week * 7 + day; return index < slots.count ? slots[index] : nil }.first { calendar.component(.day, from: $0.date) <= 7 }
                                Text(monthDay?.date.formatted(.dateTime.month(.abbreviated)) ?? " ").font(.system(size: 9)).frame(width: 28, height: 18)
                                ForEach(0..<7, id: \.self) { day in
                                    let index = week * 7 + day
                                    if index < slots.count, let value = slots[index] {
                                        Button { selected = value } label: {
                                            RoundedRectangle(cornerRadius: 4).fill(heatColor(value.tokens, maximum: maximum, vendor: vendors[value.date]))
                                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected?.date == value.date ? .white : .clear, lineWidth: 2))
                                                .frame(width: 28, height: 28)
                                        }.buttonStyle(.plain)
                                        .accessibilityLabel("\(value.date.formatted(date: .complete, time: .omitted)), \(ModelUsageFormat.tokens(value.tokens)) tokens, \(ModelUsageFormat.requests(Double(value.requests), runs: Double(value.runs))))")
                                        .help("\(value.date.formatted(date: .abbreviated, time: .omitted)): \(ModelUsageFormat.tokens(value.tokens)) tokens")
                                    } else { Color.clear.frame(width: 28, height: 28) }
                                }
                            }
                        }
                    }
                }.padding(.vertical, 4)
            }.defaultScrollAnchor(.trailing)
            if let selected {
                Text("\(selected.date.formatted(date: .complete, time: .omitted)) · \(ModelUsageFormat.tokens(selected.tokens)) tokens · \(ModelUsageFormat.requests(Double(selected.requests), runs: Double(selected.runs)))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), alignment: .leading)], alignment: .leading, spacing: 12) {
                yearStat("Active days", "\(active.count)")
                yearStat("Current streak", "\(streaks.current)d")
                yearStat("Longest streak", "\(streaks.longest)d")
                yearStat("Per active day", ModelUsageFormat.tokens(active.reduce(0) { $0 + $1.tokens } / Double(max(1, active.count))))
            }
            if let peak = active.max(by: { $0.tokens < $1.tokens }) {
                Text("Busiest \(peak.date.formatted(date: .abbreviated, time: .omitted)) · \(ModelUsageFormat.tokens(peak.tokens)) tokens")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            heatLegend
            routedVendorLegend(rows)
        }
    }

    private func yearStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

private func heatColor(_ value: Double, maximum: Double, vendor: String? = nil) -> Color {
    guard value > 0 else { return Color.white.opacity(0.045) }
    let ratio = log1p(value) / log1p(max(1, maximum))
    return displayColor(vendor).opacity(0.15 + 0.85 * ratio)
}

private func displayColor(_ identity: String?) -> Color {
    guard let identity, let provider = ProviderID(rawValue: identity) else { return ProGlassTheme.accent }
    return Color(hex: provider.accentColorHex)
}

private func routedVendorLegend(_ rows: [ModelUsageRollup]) -> some View {
    let vendors = Array(Set(rows.map { ModelUsageDisplayIdentity.provider(model: $0.model, source: $0.source) })).sorted()
    return LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), alignment: .leading)], alignment: .leading, spacing: 4) {
        ForEach(vendors, id: \.self) { vendor in
            HStack(spacing: 4) {
                Circle().fill(displayColor(vendor)).frame(width: 6, height: 6)
                Text(ProviderID(rawValue: vendor)?.displayName ?? vendor).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
    .help("Hue: the dominant routed vendor by tokens. Unknown or unprefixed models use the host's hue.")
}

private var heatLegend: some View {
    HStack(spacing: 4) {
        Text("Less")
        ForEach(0..<5) { index in RoundedRectangle(cornerRadius: 2).fill(heatColor(pow(10, Double(index)) - 1, maximum: 9999)).frame(width: 12, height: 8) }
        Text("More · logarithmic scale")
        Spacer()
    }.font(.system(size: 9)).foregroundStyle(.secondary).accessibilityElement(children: .combine)
}

/// Dense preview for the menu popover and tall dashboard. The detailed page owns exploration.
struct ModelUsageSummaryCard: View {
    @EnvironmentObject private var appState: AppStateStore
    var action: () -> Void

    var body: some View {
        let data = ModelUsageInsightData(archive: appState.modelUsage, snapshots: appState.snapshots)
        GlassCardContainer(style: .panel, accent: ProGlassTheme.accent, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: action) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Model usage").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            Text("24H · tokens · API equivalent, not billed").font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if appState.isIndexingModelUsage { ProgressView().controlSize(.mini) }
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityHint("Opens model history and heatmaps")
                if data.sources.isEmpty {
                    Text(appState.isIndexingModelUsage ? "Indexing history…" : "No history yet").font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    ForEach(data.busiest(3, window: .day, now: Date()), id: \.source.id) { source, totals in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(source.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(ModelUsageFormat.tokens(totals.tokens.total)).font(.system(size: 11, weight: .bold)).monospacedDigit()
                            Text(ModelUsageFormat.estimate(totals)).font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
