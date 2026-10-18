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

/// World Tension v2: an on-device assessment of international headlines, with its own history.
struct TensionIndexView: View {
    static let navigationTitleText = "World Tension"
    @EnvironmentObject var articleStore: ArticleStore
    @EnvironmentObject var appSettings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @State private var history: [WorldTensionReading]
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var unscoredHeadlines: [WorldTensionHeadline] = []
    @State private var selectedDay: Date?
    @State private var reassessment = 0
    private let service: WorldTensionService
    private let onUpdate: ([WorldTensionReading]) -> Void

    init(
        history: [WorldTensionReading] = [], service: WorldTensionService = .shared,
        onUpdate: @escaping ([WorldTensionReading]) -> Void = { _ in }
    ) {
        _history = State(initialValue: history)
        self.service = service
        self.onUpdate = onUpdate
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(Self.navigationTitleText).font(AppTypography.sectionTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless).keyboardShortcut(.cancelAction).help("Close (Esc)")
            }
            .padding(AppLayout.pageInset)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    if let reading = selected {
                        readingHeader(reading)
                        Text(reading.assessment.summary)
                            .font(AppTypography.lede).fixedSize(horizontal: false, vertical: true).textSelection(
                                .enabled)
                        IntelligenceLabel("Assessed on device")
                        if let comparison = comparison(reading) {
                            Text(comparison).font(AppTypography.callout).foregroundStyle(AppColor.secondaryText)
                        }
                        reasons(reading)
                        evidence(reading)
                        if history.count > 1 { trend }
                    } else if loading {
                        ProgressView("Assessing international headlines…").frame(maxWidth: .infinity)
                    } else {
                        ContentUnavailableView(
                            errorMessage == nil ? "No Assessment Yet" : "Assessment Unavailable", systemImage: "globe",
                            description: Text(
                                errorMessage ?? "Enable on-device AI and international panel collection in Settings."))
                    }
                    if appSettings.aiEnabled, appSettings.tensionCollectionOptIn,
                        !unscoredHeadlines.isEmpty
                    {
                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            Text("Current Panel Headlines").font(AppTypography.headline)
                            Text("No score was saved. These publisher headlines remain available to inspect.")
                                .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
                            ForEach(unscoredHeadlines, id: \.id) { headline in
                                Text(headline.title).font(AppTypography.body).textSelection(.enabled)
                                Text(headline.publisher).font(AppTypography.caption).foregroundStyle(
                                    AppColor.secondaryText)
                            }
                        }
                    }
                    if selected != nil, let errorMessage {
                        Text(errorMessage).font(AppTypography.caption).foregroundStyle(AppColor.caution)
                    }
                    footer
                }
                .padding(AppLayout.pageInset)
            }
        }
        .frame(width: AppLayout.tensionSheetWidth, height: AppLayout.tensionSheetHeight)
        .task(id: "\(appSettings.aiEnabled):\(appSettings.tensionCollectionOptIn):\(reassessment)") {
            await load(force: reassessment > 0)
        }
    }

    private var selected: WorldTensionReading? {
        guard appSettings.aiEnabled, appSettings.tensionCollectionOptIn else { return nil }
        guard let selectedDay else { return history.last }
        return history.min { abs($0.id.timeIntervalSince(selectedDay)) < abs($1.id.timeIntervalSince(selectedDay)) }
    }

    private func readingHeader(_ reading: WorldTensionReading) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                        Text("\(reading.assessment.score)°").font(AppTypography.tensionReading).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(reading.level.rawValue).font(AppTypography.sectionTitle).foregroundStyle(
                            AppColor.secondaryText)
                    }
                    Text("Assessed \(reading.evaluatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
                }
                Spacer()
                TensionGlyph(level: reading.level)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("World tension \(reading.assessment.score) degrees, \(reading.level.rawValue)")
            Gauge(value: Double(reading.assessment.score), in: 0...100) { Text("World Tension") }
                .gaugeStyle(.accessoryLinear).tint(AppColor.tensionScale)
                .accessibilityValue("\(reading.assessment.score) of 100")
        }
    }

    private func comparison(_ reading: WorldTensionReading) -> String? {
        let earlier = history.filter { $0.id < reading.id && $0.modelGeneration == reading.modelGeneration }
        guard let previous = earlier.last else { return nil }
        let change = reading.assessment.score - previous.assessment.score
        let movement = change == 0 ? "Unchanged" : "\(change > 0 ? "Up" : "Down") \(abs(change))°"
        return
            "\(movement) since the assessment on \(previous.evaluatedAt.formatted(date: .abbreviated, time: .omitted))."
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
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card))
    }

    private func evidence(_ reading: WorldTensionReading) -> some View {
        DisclosureGroup("Headlines Behind the Assessment") {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("C: last 24 hours · P: preceding six days").font(AppTypography.caption).foregroundStyle(
                    AppColor.secondaryText)
                ForEach(reading.headlines, id: \.id) { headline in
                    Text("[\(headline.id)] \(headline.publisher): \(headline.title)")
                        .font(AppTypography.callout).textSelection(.enabled)
                }
            }.padding(.top, AppSpacing.sm)
        }
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Assessment History").font(AppTypography.headline)
            Chart {
                ForEach(Array(history.enumerated()), id: \.element.id) { index, reading in
                    LineMark(
                        x: .value("Day", reading.id), y: .value("Assessment", reading.assessment.score),
                        series: .value("Segment", segment(index))
                    )
                    .foregroundStyle(AppColor.secondaryText)
                    PointMark(x: .value("Day", reading.id), y: .value("Assessment", reading.assessment.score))
                        .foregroundStyle(AppColor.tension(reading.level))
                        .accessibilityLabel(reading.evaluatedAt.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue("\(reading.assessment.score) degrees")
                }
            }
            .chartYScale(domain: 0...100).chartXSelection(value: $selectedDay)
            .frame(height: AppLayout.tensionChartHeight)
            Text("One assessment per UTC day; missing days remain gaps. Select a day to inspect its reasoning.")
                .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
        }
    }

    private func segment(_ index: Int) -> Int {
        guard index > 0 else { return 0 }
        return (1...index).filter { i in
            history[i].id.timeIntervalSince(history[i - 1].id) > 86400
                || history[i].modelGeneration != history[i - 1].modelGeneration
        }.count
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(
                "An AI interpretation of selected international headlines, not a measured probability of catastrophe. Publisher claims and model reasoning can be wrong."
            )
            .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
            DisclosureGroup("How World Tension Is Assessed") {
                Text(
                    "The on-device model reasons about novelty, proximity to worst case, reversibility and scope of impact. Nuclear and WMD situations carry outsized weight when supported by headlines. Current international headlines are compared with earlier coverage; no fixed formula sets the score. Explanations are checked against the supplied headlines before saving an assessment."
                )
                .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText)
            }
            HStack {
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Reassess") { reassessment += 1 }.disabled(loading)
            }.font(AppTypography.callout)
            Text("On-device AI · methodology v2 · last 24 hours · 12 international panel feeds")
                .font(AppTypography.caption).foregroundStyle(AppColor.tertiaryText)
        }
    }

    private func load(force: Bool = false) async {
        if !appSettings.aiEnabled || !appSettings.tensionCollectionOptIn {
            history = []
            unscoredHeadlines = []
            onUpdate([])
        }
        loading = true
        defer { loading = false }
        do {
            let loaded = try await service.assess(
                database: articleStore.database, now: Date(),
                aiEnabled: appSettings.aiEnabled, collectionEnabled: appSettings.tensionCollectionOptIn, force: force)
            try Task.checkCancellation()
            history = loaded
            unscoredHeadlines = []
            errorMessage = nil
            onUpdate(loaded)
        } catch is CancellationError { return } catch {
            guard !Task.isCancelled else { return }
            if appSettings.aiEnabled, appSettings.tensionCollectionOptIn {
                let accepted = try? await articleStore.database.worldTensionHistory()
                guard !Task.isCancelled, appSettings.aiEnabled, appSettings.tensionCollectionOptIn else { return }
                if let accepted { history = accepted }
                let now = Date()
                if let rows = try? await articleStore.database.tensionCorpus(
                    day: DateInterval(start: now.addingTimeInterval(-86400), end: now),
                    feedURLs: TensionMethodology.v1.panel.map(\.url))
                {
                    guard !Task.isCancelled else { return }
                    unscoredHeadlines = WorldTensionService.headlines(rows, prefix: "C", limit: 12)
                }
            }
            errorMessage = error.localizedDescription
        }
    }
}

/// Display-driven drawing, without a fixed frame interval. Only the open, active sheet owns this timeline.
struct TensionGlyph: View {
    let level: TensionLevel
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Motion time starts at the resting pose and freezes while paused, so it resumes where it stopped.
    @State private var origin = Date()
    @State private var frozen: TimeInterval = 0

    private var paused: Bool { reduceMotion || scenePhase != .active }

    var body: some View {
        TimelineView(.animation(paused: paused)) { timeline in
            let time = reduceMotion ? 0 : paused ? frozen : timeline.date.timeIntervalSince(origin)
            Canvas { context, size in Self.draw(level, in: &context, size: size, time: time) }
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
            Path(ellipseIn: square(size, radius: halo)), with: .color(AppColor.tension(.mild).opacity(0.4)),
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
        let heat = level == .warm ? 0.0 : level == .hot ? 0.5 : 1.0
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
    let reading: WorldTensionReading?
    let open: () -> Void
    var status = "Not assessed"
    var body: some View {
        Button(action: open) {
            HStack(spacing: AppSpacing.sm) {
                Circle().fill(reading.map { AppColor.tension($0.level) } ?? AppColor.secondaryText)
                    .frame(width: AppLayout.tensionDotSize, height: AppLayout.tensionDotSize).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppSpacing.textStack) {
                    Text(
                        reading.map { "\($0.assessment.score)° \($0.level.rawValue)" }
                            ?? TensionIndexView.navigationTitleText
                    )
                    .font(AppTypography.headline).monospacedDigit()
                    Text(reading == nil ? status : TensionIndexView.navigationTitleText)
                        .font(AppTypography.caption).foregroundStyle(AppColor.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Show the World Tension assessment")
        .accessibilityLabel(
            reading.map { "World tension, \($0.assessment.score) degrees, \($0.level.rawValue)" }
                ?? "World tension, \(status)"
        )
        .accessibilityHint("Opens the World Tension details")
        .transaction { $0.animation = nil }
    }
}
