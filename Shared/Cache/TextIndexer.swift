import Foundation
import os

/// High-performance text indexer with inverted index for O(1) search operations
actor TextIndexer {
    private let logger = Logger(subsystem: "com.prompt.app", category: "TextIndexer")

    // Inverted index: token -> Set of document IDs
    private var invertedIndex: [String: Set<UUID>] = [:]

    // Document store: document ID -> tokens
    private var documentTokens: [UUID: Set<String>] = [:]

    // Trigram index for fuzzy search
    private var trigramIndex: [String: Set<UUID>] = [:]

    // Token statistics for TF-IDF scoring
    private var tokenFrequency: [String: Int] = [:]
    private var documentFrequency: [String: Int] = [:]
    private var totalDocuments: Int = 0

    // Concurrent queues for parallel processing
    private let indexQueue = DispatchQueue(label: "com.promptbank.textindexer", attributes: .concurrent)

    init() async throws {
        logger.info("TextIndexer initialized")
    }

    // MARK: - Public API

    func buildIndex(for summaries: [PromptSummary]) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Clear existing index
        await clearIndex()

        // Process in parallel batches for maximum performance
        let batchSize = 100
        let summaryCount = summaries.count  // Capture count before TaskGroup

        // Process batches - PromptSummary is Sendable
        await withTaskGroup(of: Void.self) { group in
            for batch in summaries.chunked(into: batchSize) {
                group.addTask { [weak self] in
                    await self?.indexBatch(Array(batch))
                }
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.info("Built index for \(summaryCount) documents in \(elapsed)ms")
    }

    func search(query: String, in summaries: [PromptSummary]) async -> [SearchResult] {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Tokenize query
        let queryTokens = tokenize(query)
        let queryTrigrams = generateTrigrams(from: query.lowercased())

        // Find candidate documents using inverted index
        var candidates: Set<UUID> = []

        // Exact token matches
        for token in queryTokens {
            if let docs = invertedIndex[token] {
                candidates.formUnion(docs)
            }
        }

        // Fuzzy matches using trigrams
        for trigram in queryTrigrams {
            if let docs = trigramIndex[trigram] {
                candidates.formUnion(docs)
            }
        }

        // Score and rank candidates
        var results: [SearchResult] = []

        for promptId in candidates {
            guard let summary = summaries.first(where: { $0.id == promptId }) else { continue }

            let score = calculateScore(
                query: queryTokens,
                documentId: promptId,
                documentText: summary.title + " " + summary.contentPreview
            )

            if score > 0 {
                let highlights = findHighlights(
                    queryTokens: queryTokens,
                    in: summary.contentPreview
                )

                results.append(
                    SearchResult(
                        promptId: promptId,
                        score: score,
                        highlights: highlights
                    ))
            }
        }

        // Sort by score descending
        results.sort { $0.score > $1.score }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.debug("Search completed in \(elapsed)ms, found \(results.count) results")

        return results
    }

    func compactIndex() async {
        // Remove low-frequency tokens to save memory
        let threshold = 2
        invertedIndex = invertedIndex.filter { _, docs in docs.count >= threshold }
        trigramIndex = trigramIndex.filter { _, docs in docs.count >= threshold }

        logger.info("Compacted index, removed low-frequency entries")
    }

    // MARK: - Private Methods

    private func clearIndex() async {
        invertedIndex.removeAll()
        documentTokens.removeAll()
        trigramIndex.removeAll()
        tokenFrequency.removeAll()
        documentFrequency.removeAll()
        totalDocuments = 0
    }

    private func indexBatch(_ summaries: [PromptSummary]) async {
        for summary in summaries {
            await indexDocument(summary)
        }
    }

    private func indexDocument(_ summary: PromptSummary) async {
        let documentId = summary.id
        let fullText = summary.title + " " + summary.contentPreview + " " + summary.tagNames.joined(separator: " ")

        // Tokenize
        let tokens = tokenize(fullText)
        let tokenSet = Set(tokens)

        // Update document tokens
        documentTokens[documentId] = tokenSet

        // Update inverted index
        for token in tokenSet {
            invertedIndex[token, default: []].insert(documentId)
            documentFrequency[token, default: 0] += 1
        }

        // Update token frequency
        for token in tokens {
            tokenFrequency[token, default: 0] += 1
        }

        // Generate and index trigrams
        let trigrams = generateTrigrams(from: fullText.lowercased())
        for trigram in trigrams {
            trigramIndex[trigram, default: []].insert(documentId)
        }

        totalDocuments += 1
    }

    private func tokenize(_ text: String) -> [String] {
        // Fast tokenization using NSLinguisticTagger
        let options: NSLinguisticTagger.Options = [.omitWhitespace, .omitPunctuation]
        let schemes = NSLinguisticTagger.availableTagSchemes(forLanguage: "en")
        let tagger = NSLinguisticTagger(tagSchemes: schemes, options: Int(options.rawValue))

        tagger.string = text

        var tokens: [String] = []
        let range = NSRange(location: 0, length: text.utf16.count)

        tagger.enumerateTags(in: range, unit: .word, scheme: .tokenType, options: options) { _, tokenRange, _ in
            let token = (text as NSString).substring(with: tokenRange).lowercased()
            if token.count > 2 {  // Skip very short tokens
                tokens.append(token)
            }
        }

        return tokens
    }

    private func generateTrigrams(from text: String) -> Set<String> {
        var trigrams = Set<String>()
        let chars = Array(text)

        guard chars.count >= 3 else { return trigrams }

        for index in 0...(chars.count - 3) {
            let trigram = String(chars[index..<(index + 3)])
            trigrams.insert(trigram)
        }

        return trigrams
    }

    private func calculateScore(query: [String], documentId: UUID, documentText: String) -> Double {
        guard let docTokens = documentTokens[documentId] else { return 0 }

        var score = 0.0
        let querySet = Set(query)

        // TF-IDF scoring
        for token in querySet {
            guard docTokens.contains(token) else { continue }

            let tf = Double(tokenFrequency[token] ?? 0) / Double(docTokens.count)
            let df = Double(documentFrequency[token] ?? 1)
            let idf = log(Double(totalDocuments) / df)

            score += tf * idf
        }

        // Boost for exact phrase match
        if documentText.lowercased().contains(query.joined(separator: " ")) {
            score *= 2.0
        }

        // Boost for title match
        let documentTokens = tokenize(documentText)
        let titleTokens = documentTokens.prefix(10)  // Assume first 10 tokens are title-ish
        for token in querySet where titleTokens.contains(token) {
            score *= 1.5
        }

        return score
    }

    private func findHighlights(queryTokens: [String], in content: String) -> [SearchResult.TextRange] {
        var highlights: [SearchResult.TextRange] = []
        let lowercasedContent = content.lowercased()

        for token in queryTokens {
            var searchRange = lowercasedContent.startIndex..<lowercasedContent.endIndex

            while let range = lowercasedContent.range(of: token, options: .caseInsensitive, range: searchRange) {
                let start = lowercasedContent.distance(from: lowercasedContent.startIndex, to: range.lowerBound)
                let end = lowercasedContent.distance(from: lowercasedContent.startIndex, to: range.upperBound)

                highlights.append(SearchResult.TextRange(start: start, end: end))

                searchRange = range.upperBound..<lowercasedContent.endIndex
            }
        }

        // Merge overlapping highlights
        highlights.sort { $0.start < $1.start }
        var merged: [SearchResult.TextRange] = []

        for highlight in highlights {
            if let last = merged.last, last.end >= highlight.start {
                merged[merged.count - 1] = SearchResult.TextRange(
                    start: last.start,
                    end: max(last.end, highlight.end)
                )
            } else {
                merged.append(highlight)
            }
        }

        return merged
    }
}
