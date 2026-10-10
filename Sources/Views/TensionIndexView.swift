import Charts
import SwiftUI

extension Notification.Name {
    /// Settings asks the main window to show the tension sheet.
    static let showNewsTensionCommand = Notification.Name("showNewsTensionCommand")
}

/// A request from Settings to show the tension sheet. It is kept until a main window takes it, so a window that
/// Settings has to reopen still shows the sheet once it appears.
@MainActor
enum NewsTensionRequest {
    private(set) static var isPending = false

    static func post() {
        isPending = true
        NotificationCenter.default.post(name: .showNewsTensionCommand, object: nil)
    }

    /// True once per request.
    static func take() -> Bool {
        defer { isPending = false }
        return isPending
    }
}

/// The news tension experiment (#159) as a modal sheet: the current reading as a temperature, what drives it and
/// the 30-day trend. Gap days are shown as gaps, never as zero, and the series starts when panel collection began.
struct TensionIndexView: View {
    static let navigationTitleText = "News Tension"

    @EnvironmentObject var articleStore: ArticleStore
    @EnvironmentObject var appSettings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    @State private var history: [TensionHistoryDay]
    @State private var loading: Bool
    @State private var loadFailed = false
    @State private var selectedDay: Date?
    @State private var updatedAt: Date?

    private static let methodologyURL = URL(
        string: "https://github.com/marspater/NewsApp-macOS/blob/main/docs/methodology/tension-index-v1.md")!
    private let methodology = TensionMethodology.v1

    /// `history` is the series the sidebar already loaded, so the sheet opens without a spinner.
    init(history: [TensionHistoryDay] = [], updatedAt: Date? = nil) {
        _history = State(initialValue: history)
        _loading = State(initialValue: history.isEmpty)
        _updatedAt = State(initialValue: updatedAt)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    if loading && history.isEmpty {
                        ProgressView("Scoring panel coverage…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppSpacing.xl)
                    } else if loadFailed && history.isEmpty {
                        Text("The tension history could not be loaded.")
                            .foregroundStyle(AppColor.secondaryText)
                    } else if let latest = TensionHistory.latestReading(in: history) {
                        reading(latest)
                        summary
                        trend
                        drivers
                    } else {
                        insufficientData
                    }
                    footer
                }
                .padding(AppLayout.pageInset)
            }
        }
        .frame(width: 540, height: 580)
        .task {
            if history.isEmpty { await load() }
        }
    }

    // MARK: - Summary

    /// Every clause comes directly from the scored facts, regardless of AI settings.
    @ViewBuilder
    private var summary: some View {
        if let facts = TensionBriefFacts.latest(in: history) {
            Text(facts.deterministicParagraph)
                .font(AppTypography.lede)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppSpacing.md)
                .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        }
    }

    private var header: some View {
        HStack {
            Text(Self.navigationTitleText)
                .font(AppTypography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, AppLayout.pageInset)
        .padding(.vertical, AppSpacing.md)
    }

    // MARK: - Reading

    private func reading(_ day: TensionHistoryDay) -> some View {
        let index = day.score.smoothedIndex ?? 0
        let level = TensionLevel(index: index)
        return VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                        Text("\(TensionLevel.degrees(index))°")
                            .font(AppTypography.tensionReading)
                            .monospacedDigit()
                        Text(level.rawValue)
                            .font(AppTypography.sectionTitle)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                    Text(readingCaption(day))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
                Spacer()
                TensionGlyph(level: level, animated: !reduceMotion)
                    .font(AppTypography.tensionReading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "News tension \(TensionLevel.degrees(index)) degrees, \(level.rawValue), 7-day index for \(Self.dateText(day))"
            )

            Gauge(value: min(100, max(0, index)), in: 0...100) {
                Text("Tension index")
            } currentValueLabel: {
                Text("\(TensionLevel.degrees(index))")
            } minimumValueLabel: {
                Text("0")
            } maximumValueLabel: {
                Text("100")
            }
            .gaugeStyle(.accessoryLinear)
            .tint(AppColor.tensionScale)
            .labelsHidden()
            .accessibilityValue("\(TensionLevel.degrees(index)) of 100")
        }
    }

    // MARK: - Drivers

    /// What the selected day's largest contributions were. Deterministic: story headlines and their scores only.
    private var drivers: some View {
        let day = selected
        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if let day {
                Text("Largest contributions · \(Self.dateText(day))")
                    .font(AppTypography.headline)
                    .accessibilityAddTraits(.isHeader)
                if day.contributions.isEmpty {
                    Text(
                        day.coverage.status == .sufficient
                            ? "No story added to the index this day."
                            : "Too few panel feeds or regions reported this day to score it."
                    )
                    .font(AppTypography.callout)
                    .foregroundStyle(AppColor.secondaryText)
                } else {
                    ForEach(day.contributions.prefix(4), id: \.score.key) { contribution in
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                            Text(contribution.title)
                                .font(AppTypography.body)
                                .lineLimit(2)
                            Spacer(minLength: AppSpacing.sm)
                            Text(String(format: "%.1f", contribution.score.rawScore))
                                .font(AppTypography.callout.monospacedDigit())
                                .foregroundStyle(AppColor.secondaryText)
                                .accessibilityLabel("\(String(format: "%.1f", contribution.score.rawScore)) points")
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Text(
                    "\(day.coverage.reporting.count) of \(methodology.panel.count) panel feeds · \(day.coverage.regions.count) of \(methodology.panelRegions.count) regions reported"
                )
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }

    // MARK: - Trend

    private var trend: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("30-Day Trend")
                .font(AppTypography.headline)
                .accessibilityAddTraits(.isHeader)
            chart
            Text("Select a day to see its largest contributions below.")
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(Array(history.enumerated()), id: \.offset) { index, day in
                let date = Self.plotDate(day)
                if let smoothed = day.score.smoothedIndex, let daily = day.score.calibratedIndex {
                    LineMark(
                        x: .value("Day", date, unit: .day), y: .value("7-day index", smoothed),
                        series: .value("Segment", segment(of: index))
                    )
                    .foregroundStyle(AppColor.secondaryText)
                    .interpolationMethod(.monotone)
                    PointMark(x: .value("Day", date, unit: .day), y: .value("Daily index", daily))
                        .foregroundStyle(
                            AppColor.tension(TensionLevel(index: daily)).opacity(day.score.isProvisional ? 0.5 : 1)
                        )
                        .symbolSize(day.score.day.start == selected?.score.day.start ? 90 : 30)
                        .accessibilityLabel(Self.dateText(day))
                        .accessibilityValue(
                            "Daily \(Self.indexText(daily)), 7-day \(Self.indexText(smoothed))\(day.score.isProvisional ? ", provisional" : "")"
                        )
                } else {
                    RectangleMark(
                        xStart: .value("Start", day.score.day.start), xEnd: .value("End", day.score.day.end),
                        yStart: .value("Bottom", 0), yEnd: .value("Top", 100)
                    )
                    .foregroundStyle(AppColor.badgeBackground)
                    .accessibilityLabel(Self.dateText(day))
                    .accessibilityValue("Insufficient data")
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0.0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let degrees = value.as(Double.self) { Text("\(Int(degrees))°") }
                }
            }
        }
        .chartXSelection(value: $selectedDay.animation(nil))
        .frame(height: 180)
        .padding(AppSpacing.md)
        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .accessibilityLabel("News tension by day")
        .onChange(of: selectedDay) { _, date in
            // Chart selection reports any instant; snap it to the UTC day that contains it.
            if let date, history.contains(where: { $0.score.day.contains(date) }),
                !history.contains(where: { $0.score.day.start == date })
            {
                selectedDay = TensionMethodology.day(containing: date).start
            }
        }
    }

    // MARK: - States and footer

    private var insufficientData: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Not enough data yet")
                .font(AppTypography.headline)
            Text(
                appSettings.tensionCollectionOptIn
                    ? "A day is scored once at least \(methodology.minimumReportingFeeds) panel feeds from \(methodology.minimumReportingRegions) regions have reported. The history starts on the day collection began."
                    : "Turn on panel collection in Settings → Intelligence to start a history. News has no historical corpus, so the history starts on the day collection begins."
            )
            .font(AppTypography.callout)
            .foregroundStyle(AppColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(TensionMethodology.disclaimer)
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Link("How the indicator is calculated", destination: Self.methodologyURL)
                Spacer()
                Button("Recalculate") { Task { await load() } }
                    .disabled(loading)
                    .help("Score the stored panel coverage again")
            }
            .font(AppTypography.callout)
            Text("Experiment · methodology v\(methodology.version) · \(methodology.panel.count) panel feeds")
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.tertiaryText)
        }
    }

    // MARK: - Data

    private var selected: TensionHistoryDay? {
        history.first { $0.score.day.start == selectedDay } ?? TensionHistory.latestReading(in: history)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            history = try await TensionHistory.load(from: articleStore.database, now: Date())
            updatedAt = Date()
            loadFailed = false
        } catch {
            if !Task.isCancelled { loadFailed = true }
        }
    }

    // MARK: - Formatting

    private func readingCaption(_ day: TensionHistoryDay) -> String {
        var parts = ["7-day index", Self.dateText(day)]
        if day.score.isProvisional { parts.append("provisional") }
        if let updatedAt {
            parts.append("updated \(updatedAt.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    /// Each gap starts a new line segment, so the line never bridges a day without data.
    private func segment(of index: Int) -> Int {
        history.prefix(index).filter { $0.score.smoothedIndex == nil }.count
    }

    /// Noon UTC keeps the plotted calendar date the same for readers within twelve hours of UTC.
    private static func plotDate(_ day: TensionHistoryDay) -> Date {
        day.score.day.start.addingTimeInterval(12 * 60 * 60)
    }

    static func dateText(_ day: TensionHistoryDay) -> String {
        day.score.day.start.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }

    private static func indexText(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}

// MARK: - Glyph

/// A thermometer for calm and mild readings, a flame from warm up. The flame flickers unless Reduce Motion is on.
struct TensionGlyph: View {
    let level: TensionLevel
    var animated = true

    var body: some View {
        switch level {
        case .calm, .mild:
            Image(systemName: level == .calm ? "thermometer.low" : "thermometer.medium")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AppColor.tension(level))
                .accessibilityHidden(true)
        case .warm, .hot, .boiling:
            Image(systemName: "flame.fill")
                .symbolRenderingMode(.multicolor)
                .symbolEffect(.breathe.pulse.byLayer, options: .repeat(.continuous), isActive: animated)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Sidebar reading

/// The current reading at the foot of the sidebar; it opens the tension sheet.
struct TensionSidebarButton: View {
    let reading: TensionHistoryDay?
    let open: () -> Void
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: open) {
            HStack(spacing: AppSpacing.sm) {
                if let index = reading?.score.smoothedIndex {
                    let level = TensionLevel(index: index)
                    TensionGlyph(level: level, animated: !reduceMotion)
                        .font(AppTypography.sectionTitle)
                        .frame(width: AppSpacing.lg)
                    VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                        Text("\(TensionLevel.degrees(index))° \(level.rawValue)")
                            .font(AppTypography.headline)
                            .monospacedDigit()
                        Text(TensionIndexView.navigationTitleText)
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                } else {
                    Image(systemName: "thermometer.medium")
                        .font(AppTypography.sectionTitle)
                        .foregroundStyle(AppColor.secondaryText)
                        .frame(width: AppSpacing.lg)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                        Text(TensionIndexView.navigationTitleText)
                            .font(AppTypography.headline)
                        Text("Collecting data")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show what drives the news tension index")
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the news tension details")
    }

    private var accessibilityText: String {
        guard let index = reading?.score.smoothedIndex else { return "News tension, collecting data" }
        return "News tension, \(TensionLevel.degrees(index)) degrees, \(TensionLevel(index: index).rawValue)"
    }
}
