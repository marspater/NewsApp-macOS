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
    @State private var selectedDay: Date?
    @State private var reassessment = 0
    private let onUpdate: ([WorldTensionReading]) -> Void

    init(history: [WorldTensionReading] = [], onUpdate: @escaping ([WorldTensionReading]) -> Void = { _ in }) {
        _history = State(initialValue: history)
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
                            "No Assessment Yet", systemImage: "globe",
                            description: Text(
                                errorMessage ?? "Enable on-device AI and international panel collection in Settings."))
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
            onUpdate([])
        }
        loading = true
        defer { loading = false }
        do {
            let loaded = try await WorldTensionService.shared.assess(
                database: articleStore.database, now: Date(),
                aiEnabled: appSettings.aiEnabled, collectionEnabled: appSettings.tensionCollectionOptIn, force: force)
            try Task.checkCancellation()
            history = loaded
            errorMessage = nil
            onUpdate(loaded)
        } catch is CancellationError { return } catch {
            guard !Task.isCancelled else { return }
            if appSettings.aiEnabled, appSettings.tensionCollectionOptIn {
                let accepted = try? await articleStore.database.worldTensionHistory()
                guard !Task.isCancelled, appSettings.aiEnabled, appSettings.tensionCollectionOptIn else { return }
                if let accepted { history = accepted }
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

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || scenePhase != .active)) { timeline in
            let time = reduceMotion || scenePhase != .active ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let width = size.width
                let height = size.height
                switch level {
                case .zen:
                    // An open ensō ring with a slow breath; no heat, jitter or spinning navigation symbol.
                    let breath = sin(time * 0.8) * 0.025
                    let center = CGPoint(x: width * 0.5, y: height * 0.5)
                    var ring = Path()
                    ring.addArc(
                        center: center, radius: width * (0.31 + breath),
                        startAngle: .degrees(-70), endAngle: .degrees(245), clockwise: false)
                    context.stroke(
                        ring, with: .color(AppColor.tension(level)),
                        style: StrokeStyle(lineWidth: AppLayout.tensionStrokeWidth, lineCap: .round))
                    let halo = CGRect(
                        x: width * (0.07 - breath), y: height * (0.07 - breath),
                        width: width * (0.86 + breath * 2), height: height * (0.86 + breath * 2))
                    context.stroke(
                        Path(ellipseIn: halo), with: .color(AppColor.tension(level).opacity(0.2)),
                        lineWidth: AppLayout.tensionStrokeWidth)
                    let seed = CGRect(x: width * 0.47, y: height * 0.47, width: width * 0.06, height: height * 0.06)
                    context.fill(Path(ellipseIn: seed), with: .color(AppColor.tension(level)))
                case .mild:
                    // A warm sun and slow breathing halo; distinct from the water and flame states.
                    let pulse = 0.03 * sin(time * 1.2)
                    let halo = CGRect(
                        x: width * (0.14 - pulse), y: height * (0.14 - pulse), width: width * (0.72 + pulse * 2),
                        height: height * (0.72 + pulse * 2))
                    context.stroke(
                        Path(ellipseIn: halo), with: .color(AppColor.tension(level).opacity(0.4)),
                        lineWidth: AppLayout.tensionStrokeWidth)
                    context.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: width * 0.28, y: height * 0.28, width: width * 0.44, height: height * 0.44)),
                        with: .color(AppColor.tension(level)))
                case .warm, .hot, .boiling:
                    if level == .warm {
                        context.translateBy(x: width * 0.08, y: height * 0.2)
                        context.scaleBy(x: 0.84, y: 0.8)
                    }
                    let intensity = level == .warm ? 0.0 : level == .hot ? 0.5 : 1.0
                    let drift = sin(time * (1.5 + intensity)) * (0.035 + intensity * 0.015)
                    let lift = sin(time * (2.1 + intensity)) * 0.025
                    let flame = Self.flame(size: size, drift: drift, lift: lift)
                    context.fill(
                        flame,
                        with: .linearGradient(
                            Gradient(colors: [AppColor.tension(level), AppColor.tension(level), AppColor.warning]),
                            startPoint: CGPoint(x: width * 0.5, y: 0), endPoint: CGPoint(x: width * 0.5, y: height)))
                    var inner = context
                    inner.translateBy(x: width * 0.25, y: height * 0.4)
                    inner.scaleBy(x: 0.5, y: 0.6)
                    inner.fill(
                        Self.flame(size: size, drift: -drift, lift: -lift),
                        with: .linearGradient(
                            Gradient(colors: [AppColor.warning, AppColor.flameCore]), startPoint: .zero,
                            endPoint: CGPoint(x: 0, y: height)))
                    if level != .warm {
                        // Hot has two slow embers; boiling has five faster, narrower jets.
                        let count = level == .hot ? 2 : 5
                        for ember in 0..<count {
                            let phase = (time * (level == .hot ? 0.35 : 0.65) + Double(ember) / Double(count))
                                .truncatingRemainder(dividingBy: 1)
                            let x = width * (0.5 + sin(Double(ember) * 2.4 + time) * 0.23)
                            let y = height * (0.4 - phase * 0.35)
                            let radius = width * 0.025 * (1 - phase)
                            context.fill(
                                Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius * 1.7)),
                                with: .color(AppColor.caution.opacity(1 - phase)))
                        }
                    }
                }
            }
        }
        .frame(width: AppLayout.tensionIllustrationSize, height: AppLayout.tensionIllustrationSize)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
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
