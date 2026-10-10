import Charts
import SwiftUI

/// The news tension experiment (#159): what the fixed panel reported, by UTC day. Gap days are shown as gaps,
/// never as zero, and the series starts when panel collection began.
struct TensionIndexView: View {
    static let navigationTitleText = "News Tension"

    @EnvironmentObject var articleStore: ArticleStore
    @EnvironmentObject var appSettings: AppSettings

    @State private var history: [TensionHistoryDay] = []
    @State private var loading = true
    @State private var loadFailed = false
    @State private var selectedDay: Date?

    private static let methodologyURL = URL(
        string: "https://github.com/marspater/NewsApp-macOS/blob/main/docs/methodology/tension-index-v1.md")!
    private let methodology = TensionMethodology.v1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                header
                if loading && history.isEmpty {
                    ProgressView("Scoring panel coverage…")
                } else if loadFailed {
                    Text("The tension history could not be loaded.")
                        .foregroundColor(AppColor.secondaryText)
                } else if !history.contains(where: { $0.score.calibratedIndex != nil }) {
                    insufficientData
                } else {
                    chart
                    if let day = selected { details(day) }
                }
                if !history.isEmpty { dayList }
                footer
            }
            .padding(AppLayout.pageInset)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(AppColor.background)
        .navigationTitle(Self.navigationTitleText)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await load() }
                } label: {
                    Label("Recalculate", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
                .help("Score the stored panel coverage again")
            }
        }
        .task { await load() }
    }

    private var selected: TensionHistoryDay? {
        history.first { $0.score.day.start == selectedDay } ?? history.last
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            history = try await TensionHistory.load(from: articleStore.database, now: Date())
            loadFailed = false
        } catch {
            if !Task.isCancelled { loadFailed = true }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("News Tension")
                .font(AppTypography.title)
                .accessibilityAddTraits(.isHeader)
            Text("Experiment · methodology v\(methodology.version) · \(methodology.panel.count) panel feeds")
                .font(AppTypography.label)
                .foregroundColor(AppColor.secondaryText)
            Text(TensionMethodology.disclaimer)
                .font(AppTypography.callout)
                .foregroundColor(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var insufficientData: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Insufficient data")
                .font(AppTypography.headline)
            Text(
                appSettings.tensionCollectionOptIn
                    ? "A day is scored once at least \(methodology.minimumReportingFeeds) panel feeds from \(methodology.minimumReportingRegions) regions have reported. The history starts on the day collection began."
                    : "Turn on panel collection in Settings to start a history. News has no historical corpus, so the history starts on the day collection begins."
            )
            .font(AppTypography.callout)
            .foregroundColor(AppColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
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
                    .foregroundStyle(AppColor.accent)
                    .interpolationMethod(.monotone)
                    PointMark(x: .value("Day", date, unit: .day), y: .value("Daily index", daily))
                        .foregroundStyle(AppColor.accent.opacity(day.score.isProvisional ? 0.4 : 0.9))
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
                    .foregroundStyle(AppColor.secondaryText.opacity(0.12))
                    .accessibilityLabel(Self.dateText(day))
                    .accessibilityValue("Insufficient data")
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXSelection(value: $selectedDay.animation(nil))
        .frame(height: 240)
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

    private func details(_ day: TensionHistoryDay) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(Self.dateText(day))
                .font(AppTypography.headline)
                .accessibilityAddTraits(.isHeader)
            Text(
                "\(day.coverage.reporting.count) of \(methodology.panel.count) panel feeds · \(day.coverage.regions.count) of \(methodology.panelRegions.count) regions"
            )
            .font(AppTypography.callout)
            .foregroundColor(AppColor.secondaryText)
            if let daily = day.score.calibratedIndex, let smoothed = day.score.smoothedIndex {
                HStack(spacing: AppSpacing.lg) {
                    metric("Daily index", Self.indexText(daily))
                    metric("7-day index", Self.indexText(smoothed))
                }
            } else {
                Text(
                    day.coverage.status == .noData
                        ? "No panel feed reported this day."
                        : "Insufficient data: too few panel feeds or regions reported."
                )
                .font(AppTypography.callout)
            }
            if day.score.isProvisional {
                Text("Provisional: late items and event grouping can still change this day.")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColor.secondaryText)
            }
            if !day.contributions.isEmpty {
                Text("Largest contributions")
                    .font(AppTypography.label)
                    .foregroundColor(AppColor.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                ForEach(day.contributions.prefix(5), id: \.score.key) { contribution in
                    HStack(alignment: .firstTextBaseline) {
                        Text(contribution.title)
                            .font(AppTypography.body)
                            .lineLimit(2)
                        Spacer()
                        Text(String(format: "%.1f", contribution.score.rawScore))
                            .font(AppTypography.callout.monospacedDigit())
                            .foregroundColor(AppColor.secondaryText)
                            .accessibilityLabel("\(String(format: "%.1f", contribution.score.rawScore)) points")
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(AppSpacing.md)
        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }

    private var dayList: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            Text("Days")
                .font(AppTypography.label)
                .foregroundColor(AppColor.secondaryText)
                .accessibilityAddTraits(.isHeader)
            ForEach(history.reversed(), id: \.score.day.start) { day in
                Button {
                    selectedDay = day.score.day.start
                } label: {
                    HStack {
                        Text(Self.dateText(day))
                        Spacer()
                        Text(day.score.smoothedIndex.map { "7-day \(Self.indexText($0))" } ?? "Insufficient data")
                            .foregroundColor(AppColor.secondaryText)
                            .monospacedDigit()
                    }
                    .font(AppTypography.body)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, AppSpacing.xxs)
                .accessibilityAddTraits(day.score.day.start == selected?.score.day.start ? .isSelected : [])
            }
        }
    }

    private var footer: some View {
        Link("How the indicator is calculated", destination: Self.methodologyURL)
            .font(AppTypography.label)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.textStack) {
            Text(value).font(AppTypography.title.monospacedDigit())
            Text(label).font(AppTypography.caption).foregroundColor(AppColor.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Formatting

    /// Each gap starts a new line segment, so the line never bridges a day without data.
    private func segment(of index: Int) -> Int {
        history.prefix(index).filter { $0.score.smoothedIndex == nil }.count
    }

    /// Noon UTC keeps the plotted calendar date the same for readers within twelve hours of UTC.
    private static func plotDate(_ day: TensionHistoryDay) -> Date {
        day.score.day.start.addingTimeInterval(12 * 60 * 60)
    }

    private static func dateText(_ day: TensionHistoryDay) -> String {
        day.score.day.start.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }

    private static func indexText(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}
