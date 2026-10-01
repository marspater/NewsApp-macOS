import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Runtime availability status of on-device Apple Intelligence Foundation Models.
public enum ModelAvailabilityStatus: Sendable, Equatable {
    case available
    case osUnsupported(String)
    case deviceNotEligible(String)
    case modelNotReady(String)
    case languageUnsupported(String)
    case disabledByPolicy

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var reason: String? {
        switch self {
        case .available:
            return nil
        case .osUnsupported(let msg),
             .deviceNotEligible(let msg),
             .modelNotReady(let msg),
             .languageUnsupported(let msg):
            return msg
        case .disabledByPolicy:
            return "On-device AI is disabled by policy."
        }
    }
}

/// Evaluates language suitability for on-device Foundation Models.
public struct ModelLanguageSupport: Sendable {
    /// Supported languages for Foundation Models generation in the baseline plan (English).
    /// Ukrainian generation is verified separately, not promised in the base plan.
    public static let baseSupportedLanguages: Set<NLLanguage> = [.english]

    /// Detects dominant language of text using NaturalLanguage.
    public static func detectDominantLanguage(for text: String) -> NLLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        return recognizer.dominantLanguage
    }

    /// Evaluates if the language is supported for generative synthesis.
    public static func isLanguageSupportedForGeneration(_ language: NLLanguage?) -> Bool {
        guard let language = language else { return false }
        return baseSupportedLanguages.contains(language)
    }
}

/// Probes runtime capability and provides deterministic non-AI fallbacks for macOS 15 and unsupported locales.
public struct ModelRuntimeProbe: Sendable {
    public let overrideAvailable: Bool?
    public let supportedLanguages: Set<NLLanguage>

    public init(
        overrideAvailable: Bool? = nil,
        supportedLanguages: Set<NLLanguage> = ModelLanguageSupport.baseSupportedLanguages
    ) {
        self.overrideAvailable = overrideAvailable
        self.supportedLanguages = supportedLanguages
    }

    /// Probes runtime model availability and language compatibility.
    public func checkAvailability(for language: NLLanguage? = nil) -> ModelAvailabilityStatus {
        if let override = overrideAvailable {
            if !override {
                return .osUnsupported("Foundation Models unavailable (macOS 15 fallback).")
            }
            if let lang = language, !supportedLanguages.contains(lang) {
                return .languageUnsupported("Language \(lang.rawValue) is not supported for on-device generation.")
            }
            return .available
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let availability = SystemLanguageModel.default.availability
            switch availability {
            case .available:
                if let lang = language, !supportedLanguages.contains(lang) {
                    return .languageUnsupported("Language \(lang.rawValue) is not supported for on-device generation.")
                }
                return .available
            default:
                return .modelNotReady("SystemLanguageModel is not ready: \(availability).")
            }
        } else {
            return .osUnsupported("Requires macOS 26 or later.")
        }
        #else
        return .osUnsupported("FoundationModels framework is not available.")
        #endif
    }

    /// Builds a deterministic fallback overview when Foundation Models is unavailable or language is unsupported.
    /// Extracts verified evidence passages directly without generative synthesis, guaranteeing zero hallucination.
    public func buildFallbackOverview(
        eventID: String,
        passages: [EvidencePassage],
        context: OverviewVersionContext,
        title: String
    ) -> EventOverviewDocument {
        var facts: [OverviewFact] = []
        var citations: [OverviewCitation] = []
        let memberArticleIDs = Array(Set(passages.map(\.articleID))).sorted()

        for (index, passage) in passages.prefix(5).enumerated() {
            let citationID = "c_fb_\(index + 1)"
            let factID = "f_fb_\(index + 1)"

            let citation = OverviewCitation(
                id: citationID,
                articleID: passage.articleID,
                passageID: passage.id,
                passageFingerprint: passage.fingerprint,
                quote: passage.text
            )
            citations.append(citation)

            let fact = OverviewFact(id: factID, text: passage.text, citationIDs: [citationID])
            facts.append(fact)
        }

        let summaryText: String
        if let first = passages.first {
            summaryText = first.text
        } else {
            summaryText = title
        }

        let content = OverviewContent(
            title: title,
            summary: summaryText,
            facts: facts,
            citations: citations
        )

        let provenance = OverviewProvenance(
            memberArticleIDs: memberArticleIDs,
            kind: .fallbackExcerpts
        )

        return EventOverviewDocument(
            eventID: eventID,
            version: context,
            content: content,
            provenance: provenance
        )
    }
}
