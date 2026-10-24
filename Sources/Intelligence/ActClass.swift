import Foundation

/// The act a headline leads with, read from the lemmas of its primary clause (#522). Two reports of one event word
/// the act differently ("resigns", "steps down"), so a class groups lemmas; two reports whose primary clauses name
/// different acts are two events even when they share every actor, place and day (a vote and the protest after it).
/// Cues are deliberately few and unambiguous: a headline no cue fits is `unknown`, and `unknown` never vetoes.
enum ActClass: String, Codable, CaseIterable, Sendable {
    case vote, protest, attack, agreement, personnel, ruling, sanction, disaster, crash
    /// Consequence classes report what an incident left behind rather than naming an act of their own.
    case casualties, rescue
    case unknown

    var isConsequence: Bool { self == .casualties || self == .rescue }

    /// Acts that leave no casualties or rescues of their own, so a consequence report is never coverage of them.
    private static let bloodless: Set<ActClass> = [.vote, .agreement, .personnel, .ruling, .sanction]

    /// Two known classes name two different acts. A consequence report stays compatible with the incident that could
    /// have caused it ("Three dead after …" with the shooting) and with another consequence report.
    func conflicts(with other: ActClass) -> Bool {
        guard self != .unknown, other != .unknown, self != other else { return false }
        switch (isConsequence, other.isConsequence) {
        case (false, false): return true
        case (true, true): return false
        case (true, false): return Self.bloodless.contains(other)
        case (false, true): return Self.bloodless.contains(self)
        }
    }

    /// One act class when exactly one act cue is present; a consequence class only when no act cue is; `unknown` for
    /// headlines that name two acts ("says chair should resign at rally") or none.
    static func classify(lemmas: Set<String>) -> ActClass {
        let acts = Set(lemmas.compactMap { actCues[$0] })
        if let act = acts.first, acts.count == 1 { return act }
        if acts.count > 1 { return .unknown }
        if !lemmas.isDisjoint(with: rescueCues) { return .rescue }
        if !lemmas.isDisjoint(with: casualtyCues) { return .casualties }
        return .unknown
    }

    /// Multi-word cues whose single words mean something else ("steps down", "opens fire", "strikes down").
    static func phraseLemmas(in clause: String) -> Set<String> {
        let lowered = clause.lowercased()
        let range = NSRange(lowered.startIndex..., in: lowered)
        return Set(phraseCues.filter { $0.pattern.firstMatch(in: lowered, range: range) != nil }.map(\.lemma))
    }

    private static let phraseCues: [(pattern: NSRegularExpression, lemma: String)] = [
        (#"\bstep(?:s|ped|ping)?\s+(?:down|aside)\b"#, "resign"),
        (#"\bopen(?:s|ed|ing)?\s+fire\b"#, "shooting"),
        (#"\b(?:strikes?|striking|struck)\s+down\b"#, "overturn"),
        (#"\bcritical\s+condition\b"#, "injure"),
    ].compactMap { entry in (try? NSRegularExpression(pattern: entry.0)).map { (pattern: $0, lemma: entry.1) } }

    private static let actCues: [String: ActClass] = {
        var cues: [String: ActClass] = [:]
        func add(_ act: ActClass, _ words: String) {
            for word in words.split(separator: " ") { cues[String(word)] = act }
        }
        add(.vote, "vote voter election referendum ballot elect reelect runoff")
        add(.protest, "protest protester protestor rally demonstration demonstrator riot rioter unrest")
        add(
            .attack,
            "attack attacker airstrike shelling bombing bomber bombardment bombard missile shooting shooter gunman"
                + " gunmen gunfire stabbing ambush assault raid massacre")
        add(.agreement, "agreement agree accord pact treaty ceasefire truce deal")
        add(
            .personnel,
            "resign resignation appoint appointment dismiss dismissal sack oust ouster reshuffle nominate"
                + " nomination quit")
        add(
            .ruling,
            "ruling verdict convict conviction sentence acquit acquittal indict indictment arrest overturn uphold"
                + " unconstitutional")
        add(.sanction, "sanction embargo blacklist")
        add(
            .disaster,
            "earthquake quake tremor flood flooding hurricane typhoon cyclone storm tornado wildfire eruption erupt"
                + " landslide mudslide tsunami avalanche blizzard heatwave")
        add(.crash, "crash collision collide derail derailment capsize sink")
        return cues
    }()

    private static let rescueCues = Set(
        "rescue rescuer evacuate evacuation evacuee".split(separator: " ").map(String.init))
    private static let casualtyCues = Set(
        ("kill killed dead death deaths die died dying injure injured injury injuries wound wounded hurt casualty"
            + " casualties missing victim victims toll survivor survivors survive survived hospitalise hospitalize"
            + " hospitalised hospitalized").split(separator: " ").map(String.init))
}
