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
    /// The model's functions (#554): `convert_minilm.py` exports one fixed-length function per entry, `length_16` to
    /// `length_128`, sharing one set of weights, and each text runs in the shortest that holds it. A flexible 1–128
    /// length kept the whole model on the CPU; fixed lengths run on the Neural Engine.
    static let sequenceLengths = [16, 32, 64, maxSequenceLength]

    private let logger = Logger(subsystem: "com.marspater.news", category: "SentenceEmbedder")
    /// One loaded function per sequence length; empty when the model is missing or a function does not load.
    private let models: [Int: MLModel]
    private let tokenizer: BertWordPieceTokenizer?

    /// `.cpuAndNeuralEngine` by default (#554): under `.all` Core ML placed the 16- to 64-token functions on the GPU,
    /// which clustering in the background would take from the interface.
    init(modelURL: URL? = nil, vocabURL: URL? = nil, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) {
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

        var models: [Int: MLModel] = [:]
        if FileManager.default.fileExists(atPath: effectiveModelURL.path) {
            do {
                for length in Self.sequenceLengths {
                    let config = MLModelConfiguration()
                    config.computeUnits = computeUnits
                    config.functionName = "length_\(length)"
                    models[length] = try MLModel(contentsOf: effectiveModelURL, configuration: config)
                }
            } catch {
                logger.error("Failed to load MLModel from \(effectiveModelURL.path): \(error.localizedDescription)")
                models = [:]
            }
        }
        self.models = models
    }

    /// Whether on-device embeddings are ready and available.
    var isAvailable: Bool {
        !models.isEmpty && tokenizer != nil
    }

    /// Generates a 384-dimensional L2-normalized float vector for input text.
    func embed(_ text: String) -> [Float]? {
        guard let tokenizer, let input = Self.input(tokenizer, text), let model = models[input.length],
            let output = try? model.prediction(from: input.provider),
            let hidden = output.featureValue(for: "last_hidden_state")?.multiArrayValue
        else { return nil }
        return Self.pooled(hidden, tokens: input.tokens)
    }

    /// Embeds texts in one Core ML batch per sequence length (#540, #554); a text the model cannot embed keeps its
    /// position as nil. When a batch is refused, its texts run alone.
    func embedBatch(_ texts: [String]) -> [[Float]?] {
        guard let tokenizer, !models.isEmpty else { return texts.map { _ in nil } }
        let inputs = texts.map { Self.input(tokenizer, $0) }
        var vectors = [[Float]?](repeating: nil, count: texts.count)
        for (length, model) in models {
            let indices = inputs.indices.filter { inputs[$0]?.length == length }
            guard !indices.isEmpty else { continue }
            let providers = indices.compactMap { inputs[$0]?.provider }
            guard let batch = try? model.predictions(fromBatch: MLArrayBatchProvider(array: providers)) else {
                for index in indices { vectors[index] = embed(texts[index]) }
                continue
            }
            for (position, index) in indices.enumerated() {
                let hidden = batch.features(at: position).featureValue(for: "last_hidden_state")?.multiArrayValue
                vectors[index] = hidden.flatMap { Self.pooled($0, tokens: inputs[index]?.tokens ?? 0) }
            }
        }
        return vectors
    }

    private struct Input {
        let provider: MLDictionaryFeatureProvider
        let tokens: Int
        let length: Int
    }

    /// The model's two inputs at the next exported length (#540, #554): padding to 128 cost attention over 128
    /// positions for a 30-token headline, so a text takes the shortest length that holds it. The attention mask leaves
    /// the padding out and `pooled` averages the tokens present only. Values are written through the arrays' buffers.
    private static func input(_ tokenizer: BertWordPieceTokenizer, _ text: String) -> Input? {
        let encoded = tokenizer.encode(text, maxSequenceLength: maxSequenceLength)
        let tokens = encoded.attentionMask.lastIndex(of: 1).map { $0 + 1 } ?? 0
        let length = sequenceLengths.first { $0 >= tokens } ?? maxSequenceLength
        guard tokens > 0, let ids = try? MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32),
            let mask = try? MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        else { return nil }
        ids.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            _ = buffer.initialize(from: encoded.inputIDs.prefix(length))
        }
        mask.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            _ = buffer.initialize(from: encoded.attentionMask.prefix(length))
        }
        guard
            let provider = try? MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: ids), "attention_mask": MLFeatureValue(multiArray: mask),
            ])
        else { return nil }
        return Input(provider: provider, tokens: tokens, length: length)
    }

    /// Mean over the tokens present, L2-normalized, summed through the array's buffer (#540): the boxed subscript cost
    /// one `NSNumber` per element, 49,000 per text.
    private static func pooled(_ hidden: MLMultiArray, tokens: Int) -> [Float]? {
        guard hidden.shape.count == 3, hidden.shape[2].intValue == vectorDimension, hidden.shape[1].intValue >= tokens,
            tokens > 0
        else { return nil }
        var pooled = [Float](repeating: 0, count: vectorDimension)
        let tokenStride = hidden.strides[1].intValue
        let dimensionStride = Int32(hidden.strides[2].intValue)
        if hidden.dataType == .float32 {
            hidden.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                pooled.withUnsafeMutableBufferPointer { sum in
                    for token in 0..<tokens {
                        cblas_saxpy(
                            Int32(vectorDimension), 1, buffer.baseAddress! + token * tokenStride, dimensionStride,
                            sum.baseAddress!, 1)
                    }
                }
            }
        } else if hidden.dataType == .float16 {
            // The fixed-length export returns half floats (#554); summed in Float, as the boxed path below did.
            let dimensionStride = Int(dimensionStride)
            hidden.withUnsafeBufferPointer(ofType: Float16.self) { buffer in
                for token in 0..<tokens {
                    for dimension in 0..<vectorDimension {
                        pooled[dimension] += Float(buffer[token * tokenStride + dimension * dimensionStride])
                    }
                }
            }
        } else {
            for token in 0..<tokens {
                for dimension in 0..<vectorDimension {
                    pooled[dimension] += hidden[[0, NSNumber(value: token), NSNumber(value: dimension)]].floatValue
                }
            }
        }
        var scale = 1 / Float(tokens)
        vDSP_vsmul(pooled, 1, &scale, &pooled, 1, vDSP_Length(vectorDimension))
        var sumSquares: Float = 0
        vDSP_svesq(pooled, 1, &sumSquares, vDSP_Length(vectorDimension))
        if sumSquares > 0 {
            var inverse = 1 / sqrt(sumSquares)
            vDSP_vsmul(pooled, 1, &inverse, &pooled, 1, vDSP_Length(vectorDimension))
        }
        return pooled
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
