import Accelerate
import CoreML
import Foundation
import os

/// Pure-Swift WordPiece tokenizer for standard BERT / MiniLM / BGE vocabularies.
final class BertWordPieceTokenizer: Sendable {
    private let vocab: [String: Int]
    private let unkTokenId: Int
    private let clsTokenId: Int
    private let sepTokenId: Int
    private let padTokenId: Int

    init(vocabURL: URL) throws {
        let content = try String(contentsOf: vocabURL, encoding: .utf8)
        var dict: [String: Int] = [:]
        dict.reserveCapacity(30522)
        var idx = 0
        content.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                dict[trimmed] = idx
            }
            idx += 1
        }
        self.vocab = dict
        self.padTokenId = dict["[PAD]"] ?? 0
        self.unkTokenId = dict["[UNK]"] ?? 100
        self.clsTokenId = dict["[CLS]"] ?? 101
        self.sepTokenId = dict["[SEP]"] ?? 102
    }

    /// Tokenizes input text into standard input_ids and attention_mask padded or truncated to maxSequenceLength.
    func encode(_ text: String, maxSequenceLength: Int = 128) -> (inputIDs: [Int32], attentionMask: [Int32]) {
        var tokens: [Int32] = [Int32(clsTokenId)]
        let words = basicTokenize(text)

        for word in words where !word.isEmpty {
            guard tokens.count < maxSequenceLength - 1 else { break }
            let subTokens = wordPiece(word)
            for sub in subTokens {
                tokens.append(Int32(sub))
                if tokens.count >= maxSequenceLength - 1 {
                    break
                }
            }
        }
        tokens.append(Int32(sepTokenId))

        let actualLength = tokens.count
        let padCount = max(0, maxSequenceLength - actualLength)
        var attentionMask = [Int32](repeating: 1, count: actualLength)

        if padCount > 0 {
            tokens.append(contentsOf: [Int32](repeating: Int32(padTokenId), count: padCount))
            attentionMask.append(contentsOf: [Int32](repeating: 0, count: padCount))
        }

        return (tokens, attentionMask)
    }

    /// BERT's uncased basic tokenizer lowercases and strips accents: the vocabulary holds "erdogan" and "sanchez",
    /// never "erdoğan" or "sánchez", so an accented name would otherwise become one `[UNK]` token.
    private func basicTokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var currentWord = ""

        for char in text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased() {
            if char.isWhitespace {
                if !currentWord.isEmpty {
                    tokens.append(currentWord)
                    currentWord = ""
                }
            } else if char.isPunctuation || char.isSymbol {
                if !currentWord.isEmpty {
                    tokens.append(currentWord)
                    currentWord = ""
                }
                tokens.append(String(char))
            } else {
                currentWord.append(char)
            }
        }
        if !currentWord.isEmpty {
            tokens.append(currentWord)
        }
        return tokens
    }

    private func wordPiece(_ word: String) -> [Int] {
        var subTokens: [Int] = []
        var start = word.startIndex
        let maxWordLength = 100
        guard word.count <= maxWordLength else { return [unkTokenId] }

        while start < word.endIndex {
            var end = word.endIndex
            var matchedToken: Int? = nil

            while start < end {
                var candidate = String(word[start..<end])
                if start != word.startIndex {
                    candidate = "##" + candidate
                }
                if let id = vocab[candidate] {
                    matchedToken = id
                    break
                }
                end = word.index(before: end)
            }

            guard let found = matchedToken else {
                return [unkTokenId]
            }

            subTokens.append(found)
            start = end
        }

        return subTokens
    }
}

/// On-device neural sentence embedding engine using bundled CoreML + Accelerate vDSP (#127, #307).
actor SentenceEmbedder {
    static let shared = SentenceEmbedder()
    /// Bump when the tokenizer or the embedded text changes; stored vectors of older versions are recomputed.
    static let modelVersion = 2
    static let vectorDimension = 384
    static let maxSequenceLength = 128

    private let logger = Logger(subsystem: "com.marspater.news", category: "SentenceEmbedder")
    private let model: MLModel?
    private let tokenizer: BertWordPieceTokenizer?

    init(modelURL: URL? = nil, vocabURL: URL? = nil) {
        #if SWIFT_PACKAGE
            let moduleModelURL =
                Bundle.module.url(forResource: "minilm", withExtension: "mlmodelc", subdirectory: "Resources/Models")
                ?? Bundle.module.url(forResource: "minilm", withExtension: "mlmodelc", subdirectory: "Models")
            let moduleVocabURL =
                Bundle.module.url(forResource: "vocab", withExtension: "txt", subdirectory: "Resources/Models")
                ?? Bundle.module.url(forResource: "vocab", withExtension: "txt", subdirectory: "Models")
        #else
            let moduleModelURL: URL? = nil
            let moduleVocabURL: URL? = nil
        #endif

        let defaultModelURL =
            Bundle.main.url(forResource: "minilm", withExtension: "mlmodelc", subdirectory: "Models")
            ?? moduleModelURL
            ?? URL(fileURLWithPath: "Sources/Resources/Models/minilm.mlmodelc")
        let defaultVocabURL =
            Bundle.main.url(forResource: "vocab", withExtension: "txt", subdirectory: "Models")
            ?? moduleVocabURL
            ?? URL(fileURLWithPath: "Sources/Resources/Models/vocab.txt")

        let effectiveModelURL = modelURL ?? defaultModelURL
        let effectiveVocabURL = vocabURL ?? defaultVocabURL

        if FileManager.default.fileExists(atPath: effectiveVocabURL.path) {
            do {
                self.tokenizer = try BertWordPieceTokenizer(vocabURL: effectiveVocabURL)
            } catch {
                logger.error(
                    "Failed to initialize BertWordPieceTokenizer from \(effectiveVocabURL.path): \(error.localizedDescription)"
                )
                self.tokenizer = nil
            }
        } else {
            self.tokenizer = nil
        }

        if FileManager.default.fileExists(atPath: effectiveModelURL.path) {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            do {
                self.model = try MLModel(contentsOf: effectiveModelURL, configuration: config)
            } catch {
                logger.error("Failed to load MLModel from \(effectiveModelURL.path): \(error.localizedDescription)")
                self.model = nil
            }
        } else {
            self.model = nil
        }
    }

    /// Whether on-device embeddings are ready and available.
    var isAvailable: Bool {
        model != nil && tokenizer != nil
    }

    /// Generates a 384-dimensional L2-normalized float vector for input text.
    func embed(_ text: String) -> [Float]? {
        guard let model, let tokenizer else { return nil }
        let (inputIDs, attentionMask) = tokenizer.encode(text, maxSequenceLength: Self.maxSequenceLength)
        let seqLen = inputIDs.count

        guard let inMultiArray = try? MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32),
            let maskMultiArray = try? MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        else {
            return nil
        }

        for i in 0..<seqLen {
            inMultiArray[i] = NSNumber(value: inputIDs[i])
            maskMultiArray[i] = NSNumber(value: attentionMask[i])
        }

        guard
            let featureProvider = try? MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: inMultiArray),
                "attention_mask": MLFeatureValue(multiArray: maskMultiArray),
            ])
        else {
            return nil
        }

        guard let output = try? model.prediction(from: featureProvider),
            let lastHidden = output.featureValue(for: "last_hidden_state")?.multiArrayValue
        else {
            return nil
        }

        // Mean pooling over valid (non-padding) tokens
        let validTokens = max(1, attentionMask.filter { $0 == 1 }.count)
        var pooled = [Float](repeating: 0, count: Self.vectorDimension)

        for t in 0..<validTokens {
            for d in 0..<Self.vectorDimension {
                pooled[d] += lastHidden[[0, NSNumber(value: t), NSNumber(value: d)]].floatValue
            }
        }

        var scale = 1.0 / Float(validTokens)
        vDSP_vsmul(pooled, 1, &scale, &pooled, 1, vDSP_Length(Self.vectorDimension))

        // L2 Normalization using Accelerate
        var sumSquares: Float = 0
        vDSP_svesq(pooled, 1, &sumSquares, vDSP_Length(Self.vectorDimension))
        let norm = sqrt(sumSquares)
        if norm > 0 {
            var invNorm = 1.0 / norm
            vDSP_vsmul(pooled, 1, &invNorm, &pooled, 1, vDSP_Length(Self.vectorDimension))
        }

        return pooled
    }

    /// Embeds a batch of texts sequentially.
    func embedBatch(_ texts: [String]) -> [[Float]] {
        texts.compactMap { embed($0) }
    }

    /// Computes cosine similarity between two L2-normalized float vectors in < 0.1 microseconds using vDSP.
    nonisolated static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == vectorDimension, b.count == vectorDimension else { return 0.0 }
        var dot: Float = 0.0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(vectorDimension))
        return Double(dot)
    }
}
