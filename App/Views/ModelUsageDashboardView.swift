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
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    if let status = appState.modelUsageStatus {
                        Label(status, systemImage: appState.isIndexingModelUsage ? "arrow.triangle.2.circlepath" : "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = appState.modelUsageSyncError {
                        Label(error, systemImage: "icloud.slash").font(.caption).foregroundStyle(.orange)
                    }
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
                                Text("This provider supplies aggregate buckets. Charts show their reported dates; two-hour activity is available for local request logs.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ModelUsageYearGrid(rows: chartRows, now: timeline.date)
                            comparisons(data, source: sourceID, now: timeline.date)
                        }
                    }
                    rateReference
                    Text("API-equivalent estimates are hypothetical, not billed spend. Each record is priced on its own with the imported \(ModelRateCatalog.version) standard-rate table before it is added up; a long-context tier applies only when one call's prompt reached it. When a record's token split or tier is unknown the estimate is a range, never a single figure. Historical discounts, fast mode, tools and taxes may differ. Cache writes use the input rate. Reasoning is included in output. Unknown models stay unpriced; no fallback rate is used.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
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
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("MODEL INTELLIGENCE", systemImage: "chart.xyaxis.line")
                    .font(.caption.weight(.bold)).tracking(2).foregroundStyle(.cyan)
                Spacer()
                if appState.isIndexingModelUsage { ProgressView().controlSize(.small) }
            }
            Text("Every token tells a story.")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .minimumScaleFactor(0.7)
            Text("Explore models, cache efficiency and your working rhythm.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        AnalyticsPanel(title: "Your history starts here", subtitle: "Local collection on Mac · private iCloud sync to iPhone") {
            Text("Connect Codex or Claude log folders in Providers to backfill available history. Providers that already report model usage also appear here. Your quota dashboard continues updating while history is indexed.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Refresh model history") { appState.refreshModelUsage() }
                .buttonStyle(.bordered).disabled(appState.isIndexingModelUsage)
        }
    }

    private func sourcePicker(data: ModelUsageInsightData, source: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    sourceMenu(data: data, source: source)
                    modelMenu(data: data, source: source)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 8) {
                    sourceMenu(data: data, source: source)
                    modelMenu(data: data, source: source)
                }
            }
            Picker("Time window", selection: $window) {
                ForEach(ModelUsageWindow.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Text("One source at a time: local logs and API reports can describe the same requests.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func sourceMenu(data: ModelUsageInsightData, source: String) -> some View {
        Picker("Source", selection: Binding(get: { source }, set: { selectedSource = $0 })) {
            ForEach(data.sources) { Text($0.title).tag($0.id) }
        }.pickerStyle(.menu).tint(.cyan)
    }

    private func modelMenu(data: ModelUsageInsightData, source: String) -> some View {
        Picker("Model", selection: $selectedModel) {
            Text("All models").tag("")
            ForEach(Array(Set(data.entries.filter { $0.source == source && $0.tokens.total > 0 }.map(\.model))).sorted(), id: \.self) {
                Text($0).tag($0)
            }
        }.pickerStyle(.menu)
    }

    private func coverage(_ source: ModelUsageInsightSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(Color(hex: source.provider.accentColorHex)).frame(width: 7, height: 7)
                Text(source.title).font(.caption.weight(.bold))
                Spacer()
                if let date = source.scanned { Text(date, style: .relative).font(.caption2).foregroundStyle(.secondary) }
            }
            Text(source.detail).font(.caption2).foregroundStyle(.secondary)
            if let first = source.first, let last = source.last {
                Text("Observed \(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted)). Blank cells mean no recorded usage, not proof of no activity.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let issue = source.issue { Text(issue).font(.caption2).foregroundStyle(.orange) }
        }
    }

    private func headline(_ totals: ModelUsageInsightTotals, models: Int) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
            if totals.inferredTokens > 0 {
                AnalyticsMetric(title: "Measured tokens", value: ModelUsageFormat.tokens(totals.measuredTokens), footnote: "\(window.rawValue) · \(models) models", color: .cyan)
                AnalyticsMetric(title: "Estimated tokens", value: ModelUsageFormat.tokens(totals.inferredTokens), footnote: "Inferred counts, not provider-reported", color: .gray)
            } else {
                AnalyticsMetric(title: "Tracked tokens", value: ModelUsageFormat.tokens(totals.tokens.total), footnote: "\(window.rawValue) · \(models) models", color: .cyan)
            }
            AnalyticsMetric(title: "Requests", value: ModelUsageFormat.tokens(totals.requests), footnote: "Recorded calls", color: .mint)
            AnalyticsMetric(title: "Cache hit share", value: totals.cacheShare.formatted(.percent.precision(.fractionLength(1))), footnote: "Of prompt tokens", color: .purple)
            AnalyticsMetric(title: "API equivalent", value: ModelUsageFormat.estimate(totals), footnote: estimateFootnote(totals), color: .orange)
            if let cost = totals.actualUSD {
                AnalyticsMetric(title: "API reported spend", value: ModelUsageFormat.money(cost), footnote: "Billed, as reported by provider", color: .green)
            }
            if let cost = totals.reportedEstimateUSD {
                AnalyticsMetric(title: "Card estimate", value: ModelUsageFormat.money(cost), footnote: "Quota card's own method, not billed", color: .yellow)
            }
        }
    }

    private func estimateFootnote(_ totals: ModelUsageInsightTotals) -> String {
        let percent = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))
        var text = "Not billed · \(totals.coverage.formatted(percent)) exact"
        if totals.rangedTokens > 0 { text += " · \(totals.rangeCoverage.formatted(percent)) bounded" }
        return text
    }

    private func tokenMix(_ totals: ModelUsageInsightTotals) -> some View {
        AnalyticsPanel(title: "Token anatomy", subtitle: "\(window.rawValue) · reasoning is a subset of output") {
            let components: [(String, Double, Color)] = [
                ("Fresh input", totals.tokens.input, .cyan), ("Cache read", totals.tokens.cacheRead, .purple),
                ("Cache write", totals.tokens.cacheWrite, .pink), ("Output", totals.tokens.output, .mint)
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
            }.frame(height: 12).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(components.indices, id: \.self) { index in
                    let item = components[index]
                    VStack(alignment: .leading, spacing: 3) {
                        Label(item.0, systemImage: "circle.fill").font(.caption2).foregroundStyle(item.2)
                        Text(ModelUsageFormat.tokens(item.1)).font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                }
            }
            if totals.tokens.reasoning > 0 {
                Text("\(ModelUsageFormat.tokens(totals.tokens.reasoning)) reasoning tokens included in output")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if totals.tokens.unsplit > 0 {
                Text("Some records report only a total. Their input, cache and output split is unknown, so they are priced as a range.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func quotaPanel(_ snapshot: QuotaSnapshot) -> some View {
        AnalyticsPanel(title: "Quota & provider telemetry", subtitle: snapshot.displayName) {
            if snapshot.summaryWindows.isEmpty {
                Text("No quota windows reported by this source.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.summaryWindows.prefix(4)) { quota in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(quota.label).font(.caption.weight(.semibold))
                            Spacer()
                            Text(quota.leadingValueText).font(.caption.monospacedDigit())
                        }
                        if quota.total != nil {
                            ProgressView(value: min(1, max(0, quota.fractionUsed))).tint(Color(hex: snapshot.providerID.accentColorHex))
                        }
                        if let reset = quota.resetDate {
                            Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
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
                        }.font(.caption).padding(.vertical, 2)
                    }
                }.font(.caption)
            }
        }
    }

    private func windowTable(_ data: ModelUsageInsightData, source: String, now: Date) -> some View {
        let models = Array(Set(data.entries.filter { $0.source == source && $0.tokens.total > 0 && $0.end > now.addingTimeInterval(-90 * 86400) }.map(\.model))).sorted()
        return AnalyticsPanel(title: "Five-window model usage", subtitle: "Tokens / estimated API equivalent · scroll to compare") {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        Text("Model").frame(width: 180, alignment: .leading)
                        ForEach(ModelUsageWindow.allCases) { Text($0.rawValue).frame(width: 105, alignment: .trailing) }
                    }.font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    ForEach(models, id: \.self) { model in
                        GridRow(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model).font(.caption.weight(.semibold)).lineLimit(2)
                                if model == "Unknown model" { Text("Unattributed").font(.caption2).foregroundStyle(.orange) }
                            }.frame(width: 180, alignment: .leading)
                            ForEach(ModelUsageWindow.allCases) { period in
                                let rows = data.selected(source: source, model: model, window: period, now: now)
                                let totals = ModelUsageInsightTotals(rows)
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(rows.isEmpty ? "—" : ModelUsageFormat.tokens(totals.tokens.total)).font(.caption.weight(.semibold))
                                    Text(ModelUsageFormat.estimate(totals)).font(.caption2).foregroundStyle(.orange)
                                }.monospacedDigit().frame(width: 105, alignment: .trailing)
                            }
                        }
                    }
                }.padding(.vertical, 4)
            }
            Text("Local windows have five-minute boundary precision. Provider buckets wider than a window are omitted; a dash means unavailable. Estimates can be partial when models or request tiers are unknown.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func comparisons(_ data: ModelUsageInsightData, source: String, now: Date) -> some View {
        let rows = data.selected(source: source, window: window, now: now)
        let groups = Dictionary(grouping: rows.filter { $0.tokens.total > 0 }, by: \.model)
            .map { (model: $0.key, total: ModelUsageInsightTotals($0.value)) }
            .sorted { $0.total.tokens.total > $1.total.tokens.total }
        let total = rows.reduce(0) { $0 + $1.tokens.total }
        return AnalyticsPanel(title: "Model comparisons", subtitle: "\(window.rawValue) · share within the selected source") {
            ForEach(groups, id: \.model) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.model).font(.caption.weight(.semibold)).lineLimit(2)
                        Spacer()
                        Text((item.total.tokens.total / max(1, total)).formatted(.percent.precision(.fractionLength(1))))
                            .font(.caption.monospacedDigit()).foregroundStyle(.cyan)
                    }
                    ProgressView(value: item.total.tokens.total / max(1, total)).tint(.cyan)
                    Text("\(ModelUsageFormat.tokens(item.total.tokens.prompt)) input incl. cache  ·  \(ModelUsageFormat.tokens(item.total.tokens.output)) output  ·  \(ModelUsageFormat.tokens(item.total.requests)) calls")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            if groups.isEmpty { Text("No model tokens in this window.").font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Compare available sources") {
                ForEach(data.sources) { item in
                    let totals = ModelUsageInsightTotals(data.selected(source: item.id, window: window, now: now))
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.caption.weight(.semibold))
                            Text("\(ModelUsageFormat.tokens(totals.tokens.total)) tokens").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(ModelUsageFormat.estimate(totals)).font(.caption.monospacedDigit())
                            Text("API equivalent").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }
                Text("Source rows can overlap. They are not added into a combined total.").font(.caption2).foregroundStyle(.secondary)
            }.font(.caption).padding(.top, 6)
        }
    }

    private var rateReference: some View {
        AnalyticsPanel(title: "API rates & context windows", subtitle: "\(ModelRateCatalog.rates.count) catalog rows · imported \(ModelRateCatalog.version)") {
            DisclosureGroup("Browse model reference", isExpanded: $showRates) {
                TextField("Search model or provider", text: $rateSearch).textFieldStyle(.roundedBorder).padding(.vertical, 8)
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(ModelRateCatalog.rates.filter { rateSearch.isEmpty || $0.id.localizedCaseInsensitiveContains(rateSearch) }) { rate in
                        DisclosureGroup {
                            Text(rate.notes ?? "Standard API rate from the imported catalog.").font(.caption).foregroundStyle(.secondary)
                            if let threshold = rate.threshold {
                                Text("Prompt ≥ \(ModelUsageFormat.tokens(threshold)): input \(ModelUsageFormat.rate(rate.longInput)), cached \(ModelUsageFormat.rate(rate.longCached)), output \(ModelUsageFormat.rate(rate.longOutput)) per million. Every token uses the long-context tier.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if let url = URL(string: rate.url), url.scheme == "https" {
                                Link("Pricing source", destination: url).font(.caption).padding(.top, 4)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rate.model).font(.caption.weight(.semibold))
                                Text("\(rate.provider.capitalized) · \(rate.isLocalInference ? "Local inference" : rate.status.title) · \(rate.context.map { ModelUsageFormat.tokens(Double($0)) + " context" } ?? "context not listed")")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if rate.status == .estimated && !rate.isLocalInference {
                                    Text("In \(ModelUsageFormat.rate(rate.input))  ·  Cache \(ModelUsageFormat.rate(rate.cached))  ·  Out \(ModelUsageFormat.rate(rate.output)) / 1M")
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.cyan)
                                }
                            }
                        }
                        Divider()
                    }
                }
            }.font(.subheadline)
        }
    }
}

private struct AnalyticsPanel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        GlassCardContainer(style: .panel, accent: .cyan, cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                content
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AnalyticsMetric: View {
    let title: String
    let value: String
    let footnote: String
    let color: Color
    var body: some View {
        GlassCardContainer(style: .panel, accent: color, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(.title2, design: .rounded, weight: .bold)).foregroundStyle(color)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(footnote).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        }
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
                point.tokens += row.tokens.total; point.requests += row.requests; grouped[key] = point
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
        AnalyticsPanel(title: "Token volume", subtitle: "\(window.rawValue) · tap or drag to inspect") {
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
            .frame(height: 180)
            HStack {
                if let selected {
                    Text(selected.date.formatted(date: .abbreviated, time: window == .hour || window == .day ? .shortened : .omitted))
                    Spacer()
                    Text("\(ModelUsageFormat.tokens(selected.tokens)) tokens · \(selected.requests) calls").monospacedDigit()
                } else {
                    Text("Peak \(ModelUsageFormat.tokens(points.map(\.tokens).max() ?? 0))")
                    Spacer()
                    Text("\(points.filter { $0.tokens > 0 }.count) active intervals")
                }
            }.font(.caption2).foregroundStyle(.secondary)
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
        AnalyticsPanel(title: "Your working rhythm", subtitle: "90 days · two-hour cells · \(calendar.timeZone.abbreviation() ?? "local time")") {
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
            Text(selected ?? "Scroll through 90 days. Select a cell for its date, hours and token count.")
                .font(.caption2).foregroundStyle(.secondary)
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
        AnalyticsPanel(title: "A year in tokens", subtitle: "365 days · Monday–Sunday · scroll to explore") {
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
                                        .accessibilityLabel("\(value.date.formatted(date: .complete, time: .omitted)), \(ModelUsageFormat.tokens(value.tokens)) tokens, \(value.requests) calls")
                                        .help("\(value.date.formatted(date: .abbreviated, time: .omitted)): \(ModelUsageFormat.tokens(value.tokens)) tokens")
                                    } else { Color.clear.frame(width: 28, height: 28) }
                                }
                            }
                        }
                    }
                }.padding(.vertical, 4)
            }.defaultScrollAnchor(.trailing)
            if let selected {
                Text("\(selected.date.formatted(date: .complete, time: .omitted)) · \(ModelUsageFormat.tokens(selected.tokens)) tokens · \(selected.requests) calls")
                    .font(.caption).foregroundStyle(.cyan)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), alignment: .leading)], alignment: .leading, spacing: 12) {
                yearStat("Active days", "\(active.count)")
                yearStat("Current streak", "\(streaks.current)d")
                yearStat("Longest streak", "\(streaks.longest)d")
                yearStat("Per active day", ModelUsageFormat.tokens(active.reduce(0) { $0 + $1.tokens } / Double(max(1, active.count))))
            }
            if let peak = active.max(by: { $0.tokens < $1.tokens }) {
                Text("Busiest day: \(peak.date.formatted(date: .abbreviated, time: .omitted)) · \(ModelUsageFormat.tokens(peak.tokens)) tokens")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            heatLegend
            routedVendorLegend(rows)
        }
    }

    private func yearStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title3.monospacedDigit().weight(.bold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private func heatColor(_ value: Double, maximum: Double, vendor: String? = nil) -> Color {
    guard value > 0 else { return Color.white.opacity(0.045) }
    let ratio = log1p(value) / log1p(max(1, maximum))
    return displayColor(vendor).opacity(0.15 + 0.85 * ratio)
}

private func displayColor(_ identity: String?) -> Color {
    guard let identity, let provider = ProviderID(rawValue: identity) else { return .cyan }
    return Color(hex: provider.accentColorHex)
}

private func routedVendorLegend(_ rows: [ModelUsageRollup]) -> some View {
    let vendors = Array(Set(rows.map { ModelUsageDisplayIdentity.provider(model: $0.model, source: $0.source) })).sorted()
    return VStack(alignment: .leading, spacing: 5) {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 95), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(vendors, id: \.self) { vendor in
                Label(ProviderID(rawValue: vendor)?.displayName ?? vendor, systemImage: "circle.fill")
                    .font(.caption2).foregroundStyle(displayColor(vendor))
            }
        }
        Text("Hue: dominant routed vendor by tokens. Unknown or unprefixed models use the host's hue.")
            .font(.caption2).foregroundStyle(.secondary)
    }
}

private var heatLegend: some View {
    HStack(spacing: 4) {
        Text("Less")
        ForEach(0..<5) { index in RoundedRectangle(cornerRadius: 2).fill(heatColor(pow(10, Double(index)) - 1, maximum: 9999)).frame(width: 12, height: 8) }
        Text("More · logarithmic scale")
        Spacer()
    }.font(.caption2).foregroundStyle(.secondary).accessibilityElement(children: .combine)
}

/// Dense preview for the menu popover and tall dashboard. The detailed page owns exploration.
struct ModelUsageSummaryCard: View {
    @EnvironmentObject private var appState: AppStateStore
    var action: () -> Void

    var body: some View {
        let data = ModelUsageInsightData(archive: appState.modelUsage, snapshots: appState.snapshots)
        GlassCardContainer(style: .panel, accent: .cyan, cornerRadius: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: action) {
                    HStack {
                        Label("Model usage", systemImage: "chart.xyaxis.line").font(.subheadline.weight(.bold))
                        Spacer()
                        if appState.isIndexingModelUsage { ProgressView().controlSize(.small) }
                        Image(systemName: "arrow.up.right").font(.caption.weight(.bold))
                    }
                }.buttonStyle(.plain).foregroundStyle(.cyan)
                if data.sources.isEmpty {
                    Text(appState.isIndexingModelUsage ? "Indexing your model history…" : "Explore token history, models and API-equivalent estimates.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(data.sources.prefix(3)) { source in
                        let totals = ModelUsageInsightTotals(data.selected(source: source.id, window: .day, now: Date()))
                        HStack(alignment: .firstTextBaseline) {
                            Text(source.title).font(.caption).lineLimit(1)
                            Spacer()
                            Text(ModelUsageFormat.tokens(totals.tokens.total)).font(.caption.monospacedDigit().weight(.semibold))
                            Text(ModelUsageFormat.estimate(totals)).font(.caption2.monospacedDigit()).foregroundStyle(.orange)
                        }
                    }
                    Text("24H · tokens / estimated API equivalent · not billed")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Button("Explore history & heatmaps", action: action).font(.caption.weight(.semibold)).buttonStyle(.plain)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
