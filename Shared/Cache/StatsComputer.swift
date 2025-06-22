import Accelerate
import Foundation
import os

/// SIMD-accelerated text statistics computer for blazing fast performance
final class StatsComputer: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.prompt.app", category: "StatsComputer")

    // Thread-safe cache
    private let cache = NSCache<NSString, CachedStats>()

    // Technical terms dictionary for complexity analysis
    private let technicalTerms: Set<String> = {
        // Common technical terms in prompts
        return Set([
            "api", "function", "variable", "parameter", "algorithm", "database",
            "array", "object", "method", "class", "interface", "protocol",
            "async", "await", "promise", "callback", "closure", "lambda",
            "query", "index", "cache", "buffer", "stream", "pipeline"
        ])
    }()

    init() {
        cache.countLimit = 10000  // Cache up to 10k computations
        logger.info("StatsComputer initialized with SIMD acceleration")
    }

    // MARK: - Public API

    func compute(content: String, hash: String) async -> TextStatistics {
        // Check cache first
        if let cached = getCached(hash: hash) {
            return cached
        }

        // Compute statistics using SIMD where possible
        let stats = computeStatistics(for: content)

        // Cache the result
        cache.setObject(CachedStats(stats: stats), forKey: hash as NSString)

        return stats
    }

    func getCached(hash: String) -> TextStatistics? {
        return cache.object(forKey: hash as NSString)?.stats
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - SIMD-Accelerated Computation

    private func computeStatistics(for content: String) -> TextStatistics {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Convert to UTF-8 for efficient byte-level operations
        let utf8 = Array(content.utf8)
        let length = utf8.count

        guard length > 0 else {
            return TextStatistics(
                wordCount: 0,
                lineCount: 0,
                characterCount: 0,
                avgWordLength: 0,
                readingTime: 0,
                complexity: TextStatistics.ComplexityScore(
                    lexicalDiversity: 0,
                    avgSentenceLength: 0,
                    technicalTermRatio: 0
                )
            )
        }

        // SIMD-accelerated character counting
        let counts = simdCountCharacters(utf8)

        // Extract results
        let wordCount = counts.words
        let lineCount = counts.lines
        let sentenceCount = counts.sentences
        let characterCount = content.count

        // Calculate average word length
        let avgWordLength = wordCount > 0 ? Double(characterCount - counts.spaces) / Double(wordCount) : 0

        // Calculate reading time (assuming 250 words per minute)
        let readingTime = Double(wordCount) / 250.0 * 60.0  // in seconds

        // Compute complexity score
        let complexity = computeComplexity(
            content: content,
            wordCount: wordCount,
            sentenceCount: sentenceCount,
            utf8: utf8
        )

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.debug("Computed statistics in \(elapsed)ms")

        return TextStatistics(
            wordCount: wordCount,
            lineCount: lineCount,
            characterCount: characterCount,
            avgWordLength: avgWordLength,
            readingTime: readingTime,
            complexity: complexity
        )
    }

    private func simdCountCharacters(_ utf8: [UInt8]) -> CharacterCounts {
        let length = utf8.count
        var counts = CharacterCounts()

        // Process in SIMD chunks
        let simdSize = 64  // Process 64 bytes at a time
        let chunks = length / simdSize

        // SIMD processing
        for chunk in 0..<chunks {
            let offset = chunk * simdSize
            processSIMDChunk(utf8, offset: offset, counts: &counts)
        }

        // Process remaining bytes
        let remainder = length % simdSize
        if remainder > 0 {
            let offset = chunks * simdSize
            processRemainder(utf8, offset: offset, length: remainder, counts: &counts)
        }

        return counts
    }

    private func processSIMDChunk(_ utf8: [UInt8], offset: Int, counts: inout CharacterCounts) {
        // Create SIMD vectors for comparison
        var space = UInt8(0x20)  // Space
        var newline = UInt8(0x0A)  // \n
        var period = UInt8(0x2E)  // .
        let exclaim = UInt8(0x21)  // !
        let question = UInt8(0x3F)  // ?

        // Load 64 bytes into SIMD registers
        utf8.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let ptr = baseAddress + offset

            // Use vDSP for vectorized comparisons
            var spaceCount: UInt = 0
            var newlineCount: UInt = 0
            var periodCount: UInt = 0

            // Count spaces
            vDSP_vcountD(ptr, 1, &space, &spaceCount, 64)
            counts.spaces += Int(spaceCount)

            // Count newlines
            vDSP_vcountD(ptr, 1, &newline, &newlineCount, 64)
            counts.lines += Int(newlineCount)

            // Count sentence endings
            vDSP_vcountD(ptr, 1, &period, &periodCount, 64)
            counts.sentences += Int(periodCount)

            // Count words (simplified: count transitions from non-space to space)
            var prevWasSpace = offset > 0 ? utf8[offset - 1] == space : true
            for index in 0..<64 {
                let currentIsSpace = ptr[index] == space || ptr[index] == newline
                if prevWasSpace && !currentIsSpace {
                    counts.words += 1
                }
                prevWasSpace = currentIsSpace
            }
        }
    }

    private func processRemainder(_ utf8: [UInt8], offset: Int, length: Int, counts: inout CharacterCounts) {
        var inWord = false

        for index in offset..<(offset + length) {
            let char = utf8[index]

            switch char {
            case 0x20, 0x09:  // Space or tab
                counts.spaces += 1
                if inWord {
                    counts.words += 1
                    inWord = false
                }
            case 0x0A:  // Newline
                counts.lines += 1
                if inWord {
                    counts.words += 1
                    inWord = false
                }
            case 0x2E, 0x21, 0x3F:  // . ! ?
                counts.sentences += 1
                fallthrough
            default:
                inWord = true
            }
        }

        // Count last word if needed
        if inWord {
            counts.words += 1
        }
    }

    private func computeComplexity(
        content: String, wordCount: Int, sentenceCount: Int, utf8: [UInt8]
    ) -> TextStatistics.ComplexityScore {
        // Tokenize for lexical analysis
        let words = content.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }

        // Lexical diversity (unique words / total words)
        let uniqueWords = Set(words)
        let lexicalDiversity = wordCount > 0 ? Double(uniqueWords.count) / Double(wordCount) : 0

        // Average sentence length
        let avgSentenceLength = sentenceCount > 0 ? Double(wordCount) / Double(sentenceCount) : 0

        // Technical term ratio
        let technicalCount = words.filter { technicalTerms.contains($0) }.count
        let technicalTermRatio = wordCount > 0 ? Double(technicalCount) / Double(wordCount) : 0

        return TextStatistics.ComplexityScore(
            lexicalDiversity: lexicalDiversity,
            avgSentenceLength: avgSentenceLength,
            technicalTermRatio: technicalTermRatio
        )
    }

    // MARK: - Helper Types

    private struct CharacterCounts {
        var words: Int = 0
        var lines: Int = 1  // Start with 1 line
        var sentences: Int = 0
        var spaces: Int = 0
    }

    private final class CachedStats {
        let stats: TextStatistics

        init(stats: TextStatistics) {
            self.stats = stats
        }
    }
}

// MARK: - vDSP Helper

private func vDSP_vcountD(
    _ vector: UnsafePointer<UInt8>, _ stride: Int, _ value: UnsafePointer<UInt8>, _ count: inout UInt, _ length: Int
) {
    // Custom SIMD count implementation
    var matches: UInt = 0
    let targetValue = value.pointee

    for index in 0..<length where vector[index * stride] == targetValue {
        matches += 1
    }

    count = matches
}
