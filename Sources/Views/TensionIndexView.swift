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

/// World Tension v2: an on-device assessment of international headlines, with its own history. The sheet shows the
/// state `MainView` loads for every surface (#781) and asks it for a fresh assessment; it assesses nothing itself.
struct TensionIndexView: View {
    static let navigationTitleText = "World Tension"
    let state: WorldTensionState
    /// Asks the owner of `state` for an assessment that ignores the saved one.
    var reassess: () -> Void = {
        // Captures have nothing to reassess.
    }
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDay: Date?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    if let reading = selected {
                        if let explanation = state.explanation { notice(explanation) }
                        group("Assessment") {
                            readingHeader(reading)
                            summary(reading)
                        }
                        drivers(reading)
                        group {
                            DisclosureGroup {
                                reasons(reading).padding(.top, AppSpacing.sm)
                            } label: {
                                groupTitle("Factor Breakdown")
                            }
                        }
                        evidence(reading)
                        if trend.count > 1 {
                            group("Past 30 Days") { TensionTrendChart(readings: trend, selection: $selectedDay) }
                        }
                    } else if state.status == .assessing {
                        ProgressView("Assessing international headlines…").frame(maxWidth: .infinity)
                    } else {
                        ContentUnavailableView(
                            state.heading, systemImage: "globe", description: Text(state.explanation ?? ""))
                    }
                    if !state.panelHeadlines.isEmpty {
                        group("Current Panel Headlines") {
                            Text(
                                "Today has no reading yet. These publisher headlines are what the next assessment reads."
                            )
                            .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
                            headlineTable(state.panelHeadlines)
                        }
                    }
                    footer
                }
                .padding(AppLayout.pageInset)
            }
        }
        .frame(width: AppLayout.tensionSheetWidth, height: AppLayout.tensionSheetHeight)
    }

    /// The sheet title carries the page's one intelligence glyph; how the reading was made is a caption under it
    /// (DESIGN.md 8.6), in the words the sidebar and the Briefing strip use.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                IntelligenceLabel(Self.navigationTitleText).font(AppTypography.title)
                    .accessibilityAddTraits(.isHeader)
                Text(state.note ?? "Assessed on this Mac")
                    .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
            }
            Spacer()
            // The same header as the feed catalog: title and Done.
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(AppLayout.pageInset)
        .onExitCommand { dismiss() }
    }

    private var trend: [WorldTensionReading] { state.trend(days: 30) }

    private var selected: WorldTensionReading? {
        guard let current = state.reading else { return nil }
        guard let selectedDay else { return current }
        return trend.min { abs($0.id.timeIntervalSince(selectedDay)) < abs($1.id.timeIntervalSince(selectedDay)) }
            ?? current
    }

    private func notice(_ text: String) -> some View {
        NoticeView {
            Label {
                Text(text).font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(AppColor.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func readingHeader(_ reading: WorldTensionReading) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                        Text("\(reading.assessment.score)°").font(AppTypography.tensionReading).monospacedDigit()
                        Label {
                            Text(reading.level.rawValue).font(AppTypography.sectionTitle)
                                .foregroundStyle(AppColor.primaryText)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(AppColor.tension(reading.level))
                        }
                    }
                    if let comparison = comparison(reading) {
                        Text(comparison).font(AppTypography.callout).foregroundStyle(AppColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(updated(reading)).font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
                }
                Spacer()
                TensionGlyph(level: reading.level)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "World tension \(reading.assessment.score) degrees, \(reading.level.rawValue)"
                    + (reading.assessment.isEstimate == true ? ", keyword estimate" : ""))
            TensionScaleBar(score: reading.assessment.score)
        }
    }

    private func updated(_ reading: WorldTensionReading) -> String {
        "Updated \(reading.evaluatedAt.formatted(date: .abbreviated, time: .shortened))"
            + (reading.assessment.isEstimate == true ? " · Keyword estimate" : "")
    }

    /// The day's own assessment when the shown reading blends it with the week's history (methodology v3), then where
    /// the reading sits among the past month's assessments, or its change since the previous one.
    private func comparison(_ reading: WorldTensionReading) -> String? {
        let day =
            reading.id == TensionMethodology.day(containing: state.loadedAt).start
            ? "Today's assessment"
            : "Assessment on \(reading.evaluatedAt.formatted(.dateTime.month(.abbreviated).day()))"
        let assessed = reading.assessment.assessedScore.map { "\(day) \($0)°, 7-day reading shown. " }
        let text = (assessed ?? "") + (ranking(reading) ?? "")
        return text.isEmpty ? nil : text
    }

    private func ranking(_ reading: WorldTensionReading) -> String? {
        let others = state.history.filter {
            $0.id < reading.id && $0.id > reading.id.addingTimeInterval(-30 * 86400)
                && $0.modelGeneration == reading.modelGeneration && $0.assessment.isEstimate != true
        }
        if others.count >= 3 {
            let below = others.filter { $0.assessment.score < reading.assessment.score }.count
            let above = others.filter { $0.assessment.score > reading.assessment.score }.count
            let share = { (n: Int) in Int((Double(n) / Double(others.count) * 100).rounded()) }
            if below == others.count { return "The highest reading of the past month's assessed days" }
            if above == others.count { return "The lowest reading of the past month's assessed days" }
            return above >= below
                ? "Lower than \(share(above))% of assessed days in the past month"
                : "Higher than \(share(below))% of assessed days in the past month"
        }
        guard let previous = others.last else { return nil }
        let change = reading.assessment.score - previous.assessment.score
        let direction = change > 0 ? "Up" : "Down"
        let movement = change == 0 ? "Unchanged" : "\(direction) \(abs(change))°"
        return
            "\(movement) since the reading on \(previous.evaluatedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    /// A titled group of the sheet (DESIGN.md 8.6): `md` inside, on the story card surface.
    private func group<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            if let title { groupTitle(title) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ContentPanel())
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title).font(AppTypography.sectionTitle).foregroundStyle(AppColor.primaryText)
            .accessibilityAddTraits(.isHeader)
    }

    /// Panel headlines as a table: the C/P badge, publisher and headline in aligned columns.
    private func headlineTable(_ headlines: [WorldTensionHeadline]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: AppSpacing.sm, verticalSpacing: AppSpacing.xs) {
            ForEach(headlines, id: \.id) { headline in
                GridRow {
                    TagView(title: String(headline.id.prefix(1)))
                        .accessibilityLabel(headline.id.hasPrefix("C") ? "Last 24 hours" : "Preceding six days")
                    EyebrowText(headline.publisher)
                    Text(headline.title).font(AppTypography.callout).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// The lead sentence in bold, then the synthesis; readings saved before leads existed show the synthesis alone.
    private func summary(_ reading: WorldTensionReading) -> some View {
        Group {
            if let lead = reading.assessment.lead {
                Text(lead).bold() + Text(" ") + Text(reading.assessment.summary)
            } else {
                Text(reading.assessment.summary)
            }
        }
        .font(AppTypography.lede).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    @ViewBuilder
    private func drivers(_ reading: WorldTensionReading) -> some View {
        let headlines = reading.drivingHeadlines
        if !headlines.isEmpty {
            group("What's Driving It") {
                Grid(
                    alignment: .leadingFirstTextBaseline, horizontalSpacing: AppSpacing.sm,
                    verticalSpacing: AppSpacing.sm
                ) {
                    ForEach(headlines, id: \.id) { headline in
                        GridRow {
                            EyebrowText(headline.publisher)
                            if let link = headline.webURL {
                                Link(headline.title, destination: link).font(AppTypography.body)
                                    .multilineTextAlignment(.leading).help("Open the story in your browser")
                            } else {
                                Text(headline.title).font(AppTypography.body).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }

    private func reasons(_ reading: WorldTensionReading) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            ForEach(WorldTensionFactor.allCases, id: \.self) { factor in
                if let reason = reading.assessment.reasons.first(where: { $0.factor == factor }) {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(factor.rawValue).font(AppTypography.headline)
                        Text(reason.explanation).font(AppTypography.body).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func evidence(_ reading: WorldTensionReading) -> some View {
        group {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("C: last 24 hours · P: preceding six days").font(AppTypography.caption).foregroundStyle(
                        AppColor.secondaryText)
                    headlineTable(reading.headlines)
                }.padding(.top, AppSpacing.sm)
            } label: {
                groupTitle("All Panel Headlines")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(
                "An AI interpretation of selected international headlines, not a measured probability of catastrophe. Publisher claims and model reasoning can be wrong."
            )
            .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
            DisclosureGroup("How World Tension Is Assessed") {
                Text(
                    "The on-device model reasons about novelty, proximity to worst case, reversibility and scope of impact. Nuclear and WMD situations carry outsized weight when supported by headlines. Current international headlines are compared with earlier coverage; no fixed formula sets the score. Before an assessment is saved, every place, person and figure it names is checked against the supplied headlines. Royal, celebrity, sport and lifestyle stories are left out. The reading shown is the weighted average of the past seven days' assessments, plus up to 9° when the assessment rose on consecutive days. When no assessment exists for the day, a labelled keyword estimate of the current headlines is shown as it is and never enters the average. It is not saved while the model is unavailable; when the model declines the headlines, it is kept as the day's reading until new headlines or Reassess bring an assessment."
                )
                .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Last 24 hours · \(TensionMethodology.v1.panel.count) international panel feeds")
                    .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
                Spacer()
                if state.isLoading { ProgressView().controlSize(.small).accessibilityHidden(true) }
                Button("Reassess", action: reassess)
                    .disabled(state.isLoading || !state.aiEnabled || !state.collectionEnabled)
                    .help("Assess today's headlines again on this Mac")
                    .accessibilityValue(state.isLoading ? "Assessing" : "")
            }
            .font(AppTypography.callout)
        }
    }
}

/// The sheet's trend: one point per UTC day in its band colour, a line that breaks at missing days and model changes,
/// and the axis labelled in UTC days, the days the readings belong to. Selecting a day selects its reading.
struct TensionTrendChart: View {
    let readings: [WorldTensionReading]
    @Binding var selection: Date?

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    var body: some View {
        let segments = WorldTensionState.segments(readings)
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Chart {
                ForEach(Array(readings.enumerated()), id: \.element.id) { index, reading in
                    LineMark(
                        x: .value("Day", reading.id), y: .value("Reading", reading.assessment.score),
                        series: .value("Segment", segments[index])
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(AppColor.secondaryText)
                    PointMark(x: .value("Day", reading.id), y: .value("Reading", reading.assessment.score))
                        .foregroundStyle(AppColor.tension(reading.level))
                        .accessibilityLabel(reading.evaluatedAt.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(
                            "\(reading.assessment.score) degrees"
                                + (reading.assessment.isEstimate == true ? ", keyword estimate" : ""))
                }
            }
            .chartYScale(domain: 0...100).chartXSelection(value: $selection)
            // West of UTC a local axis labelled each reading with the day before.
            .environment(\.timeZone, .gmt)
            .environment(\.calendar, Self.utcCalendar)
            .frame(height: AppLayout.tensionChartHeight)
            Text("One reading per UTC day; missing days remain gaps. Select a day to inspect its reasoning.")
                .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
        }
    }
}

/// The full 0–100 scale with the band colours and a marker at the current score.
struct TensionScaleBar: View {
    let score: Int
    @Environment(\.effectiveContrast) private var contrast

    var body: some View {
        VStack(spacing: AppSpacing.xs) {
            GeometryReader { geometry in
                Capsule()
                    .fill(
                        LinearGradient(gradient: AppColor.tensionScale, startPoint: .leading, endPoint: .trailing)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(AppColor.markerOutline(for: contrast), lineWidth: AppLayout.hairline)
                    )
                    .overlay(alignment: .leading) {
                        Capsule().fill(AppColor.primaryText)
                            .frame(width: AppLayout.tensionStrokeWidth, height: AppLayout.tensionScaleMarkerHeight)
                            .shadow(color: AppShadow.cardRestingColor, radius: 2, x: 0, y: 1)
                            .offset(
                                x: geometry.size.width * CGFloat(min(100, max(0, score))) / 100
                                    - AppLayout.tensionStrokeWidth / 2)
                    }
            }
            .frame(height: AppLayout.tensionScaleHeight)
            .padding(.vertical, (AppLayout.tensionScaleMarkerHeight - AppLayout.tensionScaleHeight) / 2)
            HStack {
                Text("0°")
                Spacer()
                Text("50°")
                Spacer()
                Text("100°")
            }
            .font(AppTypography.caption).foregroundStyle(AppColor.tertiaryText(for: contrast)).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("World Tension scale")
        .accessibilityValue("\(score) degrees")
    }
}

/// Display-driven drawing, without a fixed frame interval. Only the open, active sheet owns this timeline.
struct TensionGlyph: View {
    let level: TensionLevel
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appearsActive) private var appearsActive
    /// Motion time starts at the resting pose and freezes while paused, so it resumes where it stopped.
    @State private var origin = Date()
    @State private var frozen: TimeInterval = 0

    /// Paused with Reduce Motion and whenever its window is not the active one (DESIGN.md 6).
    private var paused: Bool { reduceMotion || scenePhase != .active || !appearsActive }

    private func animationTime(for date: Date) -> TimeInterval {
        if reduceMotion {
            return 0
        } else if paused {
            return frozen
        } else {
            return date.timeIntervalSince(origin)
        }
    }

    var body: some View {
        TimelineView(.animation(paused: paused)) { timeline in
            Canvas { context, size in
                Self.draw(level, in: &context, size: size, time: animationTime(for: timeline.date))
            }
        }
        .onChange(of: paused) { _, isPaused in
            if isPaused {
                frozen = reduceMotion ? 0 : Date().timeIntervalSince(origin)
            } else {
                origin = Date().addingTimeInterval(-frozen)
            }
        }
        .frame(width: AppLayout.tensionIllustrationSize, height: AppLayout.tensionIllustrationSize)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// Draws one frame. Time zero is the resting pose shown with Reduce Motion; every motion is continuous in time,
    /// and anything that restarts (the ensō stroke, each spark) is invisible at its restart.
    private static func draw(_ level: TensionLevel, in context: inout GraphicsContext, size: CGSize, time: Double) {
        switch level {
        case .zen: drawZen(in: &context, size: size, time: time)
        case .mild: drawSun(in: &context, size: size, time: time)
        case .warm, .hot, .boiling: drawFire(level, in: &context, size: size, time: time)
        }
    }

    private static func drawZen(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let width = size.width
        let height = size.height
        // Hold the ensō, let it dissolve, pause, then brush a fresh stroke that settles back into the hold.
        let cycle = time.truncatingRemainder(dividingBy: 8)
        let dissolve = smooth((cycle - 2.4) / 1.2)
        let opacity = cycle < 4 ? 1 - dissolve : smooth((cycle - 4) / 0.2)
        let progress = cycle < 4 ? 1 : smooth((cycle - 4) / 3)
        let scale = cycle < 4 ? 1 + 0.05 * dissolve : 1
        context.opacity = opacity
        context.translateBy(x: width / 2, y: height / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -width / 2, y: -height / 2)
        enso(in: &context, size: size, progress: progress, color: AppColor.tension(.zen))
    }

    private static func drawSun(in context: inout GraphicsContext, size: CGSize, time: Double) {
        // A warm sun whose halo breathes and releases one faint ripple per breath.
        let breath = time / 5
        let pulse = 0.03 * sin(breath * 2 * .pi)
        let halo = 0.36 + pulse
        context.stroke(
            Path(ellipseIn: square(size, radius: halo)), with: .color(AppColor.tensionHalo),
            lineWidth: AppLayout.tensionStrokeWidth)
        let ripple = breath - floor(breath)
        context.stroke(
            Path(ellipseIn: square(size, radius: 0.24 + ripple * 0.25)),
            with: .color(AppColor.tension(.mild).opacity(0.3 * sin(ripple * .pi) * (1 - ripple))),
            lineWidth: AppLayout.tensionStrokeWidth * (1 - 0.5 * ripple))
        context.fill(Path(ellipseIn: square(size, radius: 0.22)), with: .color(AppColor.tension(.mild)))
    }

    private static func drawFire(
        _ level: TensionLevel, in context: inout GraphicsContext, size: CGSize, time: Double
    ) {
        let width = size.width
        let height = size.height
        let heat: Double
        if level == .warm {
            heat = 0.0
        } else if level == .hot {
            heat = 0.5
        } else {
            heat = 1.0
        }
        if level == .warm {
            context.translateBy(x: width * 0.08, y: height * 0.2)
            context.scaleBy(x: 0.84, y: 0.8)
        }
        // Two incommensurate waves per parameter, so the flicker never visibly repeats or resets.
        let fire = time * (1 + heat)
        let drift = (0.03 + heat * 0.015) * (sin(fire * 1.6) + 0.4 * sin(fire * 4.1 + 1))
        let lift = 0.025 * (sin(fire * 2.2 + 0.5) + 0.5 * sin(fire * 5.3))
        let innerDrift = (0.03 + heat * 0.015) * (sin(fire * 2.1 + 2) + 0.4 * sin(fire * 4.7))
        let innerLift = 0.03 * sin(fire * 3.1 + 1.3)
        context.fill(
            flame(size: size, drift: drift, lift: lift),
            with: .linearGradient(
                Gradient(colors: [AppColor.tension(level), AppColor.tension(level), AppColor.warning]),
                startPoint: CGPoint(x: width * 0.5, y: 0), endPoint: CGPoint(x: width * 0.5, y: height)))
        var inner = context
        inner.translateBy(x: width * 0.25, y: height * 0.4)
        inner.scaleBy(x: 0.5, y: 0.6)
        inner.fill(
            flame(size: size, drift: innerDrift, lift: innerLift),
            with: .linearGradient(
                Gradient(colors: [AppColor.warning, AppColor.flameCore]), startPoint: .zero,
                endPoint: CGPoint(x: 0, y: height)))
        guard level != .warm else { return }
        renderSparks(level, in: &context, size: size, time: time)
    }

    private static func renderSparks(
        _ level: TensionLevel, in context: inout GraphicsContext, size: CGSize, time: Double
    ) {
        let width = size.width
        let height = size.height
        // Sparks rise and fade; each one fades in from nothing and starts its next flight elsewhere.
        let count = level == .hot ? 4 : 18
        let rate = level == .hot ? 0.4 : 1.2
        for ember in 0..<count {
            let clock = time * rate + Double(ember) / Double(count)
            let phase = clock - floor(clock)
            let seed = Double(ember) * 7.3 + floor(clock) * 13.1
            let origin = 0.36 + 0.28 * noise(seed)
            let x = width * (origin + (origin - 0.5) * 0.6 * phase + 0.04 * sin(phase * 6 + seed) * phase)
            let y = height * (0.45 - phase * (0.36 + 0.1 * noise(seed + 1)))
            let radius = width * (0.022 + 0.01 * noise(seed + 2)) * (1 - 0.6 * phase)
            context.fill(
                Path(ellipseIn: CGRect(x: x - radius / 2, y: y - radius, width: radius, height: radius * 1.7)),
                with: .color(AppColor.caution.opacity(smooth(phase / 0.12) * (1 - phase))))
        }
    }

    /// An open ensō brushed clockwise from the lower left: a heavy rounded press that thins and splits into dry
    /// bristles toward its tail. `progress` reveals the stroke with a rounded brush head.
    private static func enso(in context: inout GraphicsContext, size: CGSize, progress: Double, color: Color) {
        guard progress > 0 else { return }
        let weight = 0.075
        func halfWidth(_ f: Double) -> Double {
            // Round caps: a quarter-circle profile over roughly one brush width at each end.
            func cap(_ distance: Double) -> Double {
                let t = min(1, max(0, distance / 0.04))
                return sqrt(1 - (1 - t) * (1 - t))
            }
            return weight * cap(f) * cap(progress - f) * (1 - 0.55 * smooth((f - 0.1) / 0.9))
        }
        func band(from start: Double, offset: Double, half: @escaping (Double) -> Double) -> Path {
            var path = Path()
            guard progress > start else { return path }
            let samples = max(8, Int(240 * (progress - start)))
            func point(_ index: Int, _ side: Double) -> CGPoint {
                let f = start + (progress - start) * Double(index) / Double(samples)
                let angle = (115 + 330 * f) * .pi / 180
                let radius = 0.325 + 0.02 * f + offset * halfWidth(f) + side * half(f)
                return CGPoint(
                    x: size.width * (0.5 + radius * cos(angle)), y: size.height * (0.5 + radius * sin(angle)))
            }
            path.move(to: point(0, 1))
            for index in 1...samples { path.addLine(to: point(index, 1)) }
            for index in (0...samples).reversed() { path.addLine(to: point(index, -1)) }
            path.closeSubpath()
            return path
        }
        let gaps = [
            DryBrushGap(offset: 0.88, start: 0.04, width: 0.07), DryBrushGap(offset: -0.86, start: 0.22, width: 0.07),
            DryBrushGap(offset: 0.8, start: 0.16, width: 0.13), DryBrushGap(offset: 0.45, start: 0.3, width: 0.1),
            DryBrushGap(offset: -0.72, start: 0.36, width: 0.11), DryBrushGap(offset: -0.2, start: 0.48, width: 0.12),
            DryBrushGap(offset: 0.15, start: 0.6, width: 0.1), DryBrushGap(offset: 0.62, start: 0.7, width: 0.08),
            DryBrushGap(offset: -0.48, start: 0.76, width: 0.08),
        ]
        context.drawLayer { layer in
            layer.fill(band(from: 0, offset: 0, half: halfWidth), with: .color(color))
            layer.blendMode = .destinationOut
            for gap in gaps {
                layer.fill(
                    band(from: gap.start, offset: gap.offset) { f in
                        weight * gap.width * smooth((f - gap.start) / (1 - gap.start))
                    }, with: .color(color))
            }
        }
    }

    /// A dry-brush gap: offset across the stroke, where along it the gap opens, and how wide it grows.
    private struct DryBrushGap {
        let offset: Double
        let start: Double
        let width: Double
    }

    private static func square(_ size: CGSize, radius: Double) -> CGRect {
        CGRect(
            x: size.width * (0.5 - radius), y: size.height * (0.5 - radius), width: size.width * radius * 2,
            height: size.height * radius * 2)
    }

    private static func smooth(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// A repeatable pseudo-random value in 0..<1.
    private static func noise(_ seed: Double) -> Double {
        let value = sin(seed * 12.9898) * 43758.5453
        return value - floor(value)
    }

    private static func flame(size: CGSize, drift: Double, lift: Double) -> Path {
        let w = size.width
        let h = size.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.5, y: h * 0.96))
        path.addCurve(
            to: CGPoint(x: w * 0.26, y: h * 0.46), control1: CGPoint(x: w * 0.04, y: h * 0.95),
            control2: CGPoint(x: w * 0.12, y: h * 0.64))
        path.addCurve(
            to: CGPoint(x: w * (0.56 + drift), y: h * (0.1 + lift)), control1: CGPoint(x: w * 0.4, y: h * 0.6),
            control2: CGPoint(x: w * (0.48 + drift), y: h * 0.38))
        path.addCurve(
            to: CGPoint(x: w * 0.73, y: h * 0.57), control1: CGPoint(x: w * (0.53 + drift), y: h * 0.33),
            control2: CGPoint(x: w * 0.86, y: h * 0.35))
        path.addCurve(
            to: CGPoint(x: w * 0.5, y: h * 0.96), control1: CGPoint(x: w * 1.0, y: h * 0.82),
            control2: CGPoint(x: w * 0.86, y: h * 0.98))
        path.closeSubpath()
        return path
    }
}

/// The sidebar is intentionally static: no symbol effects or perpetual redraws in navigation chrome.
struct TensionSidebarButton: View {
    /// The state the sheet and the Briefing strip show too (#781).
    let state: WorldTensionState
    let open: () -> Void
    @Environment(\.effectiveContrast) private var contrast

    private var reading: WorldTensionReading? { state.reading }

    private var readingHeadline: String {
        if let reading {
            return "\(reading.assessment.score)° \(reading.level.rawValue)"
        }
        return TensionIndexView.navigationTitleText
    }

    /// The state's note in the words the other surfaces use; today's assessment names the indicator instead.
    private var readingSubheadline: String {
        state.note ?? TensionIndexView.navigationTitleText
    }

    private var statusDot: some View {
        Circle()
            .fill(reading.map { AppColor.tension($0.level) } ?? AppColor.secondaryText)
            .frame(width: AppLayout.tensionDotSize, height: AppLayout.tensionDotSize)
            .overlay(
                Circle()
                    .strokeBorder(AppColor.markerOutline(for: contrast), lineWidth: AppLayout.hairline)
            )
            .accessibilityHidden(true)
    }

    private var textStack: some View {
        VStack(alignment: .leading, spacing: AppSpacing.textStack) {
            Text(readingHeadline)
                .font(AppTypography.headline)
                .monospacedDigit()
                .foregroundStyle(AppColor.primaryText)

            Text(readingSubheadline)
                .font(AppTypography.caption)
                .foregroundStyle(AppColor.secondaryText)
                .lineLimit(1)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(AppTypography.eyebrow)
            .foregroundStyle(AppColor.tertiaryText(for: contrast))
            .accessibilityHidden(true)
    }

    private var buttonContent: some View {
        HStack(spacing: AppSpacing.sm) {
            statusDot
            textStack
            Spacer(minLength: 0)
            chevron
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
    }

    var body: some View {
        Button(action: open) {
            buttonContent
        }
        // The system accessory-bar style draws the hover highlight.
        .buttonStyle(.accessoryBar)
        .help("Show the World Tension assessment")
        .accessibilityLabel(
            (reading.map { "World tension, \($0.assessment.score) degrees, \($0.level.rawValue)" } ?? "World tension")
                + (state.note.map { ", \($0)" } ?? "")
        )
        .accessibilityHint("Opens the World Tension details")
        .transaction { $0.animation = nil }
    }
}
