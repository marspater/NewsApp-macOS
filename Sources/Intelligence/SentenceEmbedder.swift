import Accelerate
import CoreML
import Foundation
import os

/// Pure-Swift WordPiece tokenizer for standard BERT / MiniLM / BGE vocabularies.
/// One pair of texts as the pair model reads it (#525).
struct PairEncoding: Equatable, Sendable {
    var inputIDs: [Int32]
    var attentionMask: [Int32]
    var tokenTypeIDs: [Int32]
}

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

    /// Every word piece of the text, unpadded and without special tokens.
    func pieces(_ text: String) -> [Int] {
        basicTokenize(text).filter { !$0.isEmpty }.flatMap { wordPiece($0) }
    }

    /// `[CLS] a [SEP] b [SEP]` with longest-first truncation (b on ties), type ids 0 then 1, padded to
    /// `maxSequenceLength`. `script/training/train_pair_model.py` encodes its training pairs exactly so (#525).
    func encodePair(_ a: String, _ b: String, maxSequenceLength: Int = 256) -> PairEncoding {
        var first = pieces(a)
        var second = pieces(b)
        while first.count + second.count > maxSequenceLength - 3 {
            if first.count > second.count { first.removeLast() } else { second.removeLast() }
        }
        let ids = [clsTokenId] + first + [sepTokenId] + second + [sepTokenId]
        let padding = max(0, maxSequenceLength - ids.count)
        let types = Array(repeating: 0, count: first.count + 2) + Array(repeating: 1, count: second.count + 1)
        return PairEncoding(
            inputIDs: (ids + Array(repeating: padTokenId, count: padding)).map { Int32($0) },
            attentionMask: (Array(repeating: 1, count: ids.count) + Array(repeating: 0, count: padding)).map {
                Int32($0)
            },
            tokenTypeIDs: (types + Array(repeating: 0, count: padding)).map { Int32($0) })
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

/// A bundled resource: the app's `Models` folder, the package bundle, then the checkout (test runners).
private func bundledModelResource(_ name: String, _ ext: String) -> URL {
    #if SWIFT_PACKAGE
        let moduleURL =
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources/Models")
            ?? Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Models")
    #else
        let moduleURL: URL? = nil
    #endif
    return Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Models")
        ?? moduleURL
        ?? URL(fileURLWithPath: "Sources/Resources/Models/\(name).\(ext)")
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
        let effectiveModelURL = modelURL ?? bundledModelResource("minilm", "mlmodelc")
        let effectiveVocabURL = vocabURL ?? bundledModelResource("vocab", "txt")

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

    /// Embeds a batch of texts sequentially; a text the model cannot embed keeps its position as nil.
    func embedBatch(_ texts: [String]) -> [[Float]?] {
        texts.map { embed($0) }
    }

    /// Computes cosine similarity between two L2-normalized float vectors in < 0.1 microseconds using vDSP.
    nonisolated static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == vectorDimension, b.count == vectorDimension else { return 0.0 }
        var dot: Float = 0.0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(vectorDimension))
        return Double(dot)
    }
}

/// The project's own pair cross-encoder (#525): the probability that two texts report one event, from MiniLM fine-tuned
/// on pairs mined from library copies (`script/training/train_pair_model.py`). Unavailable without the bundled model;
/// the matcher then decides as it did before.
actor PairScorer {
    static let shared = PairScorer()
    static let maxSequenceLength = 256

    private let logger = Logger(subsystem: "com.marspater.news", category: "PairScorer")
    private let model: MLModel?
    private let tokenizer: BertWordPieceTokenizer?
    /// Probabilities by text pair for the app's lifetime: the texts determine the answer, so passes that meet the same
    /// unmerged pair again do not run the model again. ponytail: cleared at 20,000 entries; persist if relaunches matter.
    private var cache: [Int: Double] = [:]

    init(modelURL: URL? = nil, vocabURL: URL? = nil) {
        let modelURL = modelURL ?? bundledModelResource("pairscorer", "mlmodelc")
        let vocabURL = vocabURL ?? bundledModelResource("vocab", "txt")
        tokenizer = try? BertWordPieceTokenizer(vocabURL: vocabURL)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            model = nil
            return
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            model = try MLModel(contentsOf: modelURL, configuration: config)
        } catch {
            logger.error("Failed to load the pair model: \(error.localizedDescription)")
            model = nil
        }
    }

    var isAvailable: Bool { model != nil && tokenizer != nil }

    /// The mean of both orders, since a cross-encoder reads its two inputs differently.
    func probability(_ a: String, _ b: String) -> Double? {
        let key = (a < b ? a + "\u{0}" + b : b + "\u{0}" + a).hashValue
        if let cached = cache[key] { return cached }
        guard let forward = score(a, b), let backward = score(b, a) else { return nil }
        if cache.count >= 20_000 { cache.removeAll() }
        cache[key] = (forward + backward) / 2
        return cache[key]
    }

    private func score(_ a: String, _ b: String) -> Double? {
        guard let model, let tokenizer else { return nil }
        let encoded = tokenizer.encodePair(a, b, maxSequenceLength: Self.maxSequenceLength)
        var inputs: [String: MLFeatureValue] = [:]
        for (name, values) in [
            ("input_ids", encoded.inputIDs), ("attention_mask", encoded.attentionMask),
            ("token_type_ids", encoded.tokenTypeIDs),
        ] {
            guard let array = try? MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32) else {
                return nil
            }
            for (index, value) in values.enumerated() { array[index] = NSNumber(value: value) }
            inputs[name] = MLFeatureValue(multiArray: array)
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: inputs),
            let output = try? model.prediction(from: provider),
            let probability = output.featureValue(for: "probability")?.multiArrayValue
        else { return nil }
        return probability[0].doubleValue
    }
}
