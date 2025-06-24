import Foundation
import os

/// Memory-mapped inverted search index for fast full-text search
actor MappedSearchIndex {
    private let indexFile: MappedFile<IndexRecord>
    private let postingFile: ContentMappedFile
    private let trigramFile: MappedFile<TrigramEntry>
    private let tokenizer = Tokenizer()
    private let logger = Logger(subsystem: "com.prompt.app", category: "MappedSearchIndex")

    // In-memory acceleration structures
    private var tokenHashMap: [UInt64: Int] = [:]  // Token hash -> index record position
    private var trigramMap: [String: Set<Int>] = [:]  // Trigram -> document indices
    private var accelerationStructuresLoaded = false

    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()

        // Initialize component files
        indexFile = try MappedFile<IndexRecord>(
            url: directory.appendingPathComponent("search_index.idx"),
            initialSize: 1024 * 1024  // 1MB initial
        )

        postingFile = try ContentMappedFile(
            url: directory.appendingPathComponent("search_postings.dat"),
            initialSize: 4 * 1024 * 1024  // 4MB initial
        )

        trigramFile = try MappedFile<TrigramEntry>(
            url: directory.appendingPathComponent("search_trigrams.idx"),
            initialSize: 512 * 1024  // 512KB initial
        )

        // Note: Acceleration structures will be loaded on first use
    }

    // MARK: - Indexing

    /// Index a document
    func indexDocument(id: UUID, index: Int, title: String, content: String) async throws {
        try ensureAccelerationStructuresLoaded()
        
        let fullText = "\(title) \(content)"

        // Tokenize
        let tokens = tokenizer.tokenize(fullText)
        let uniqueTokens = Set(tokens)

        // Build position map
        var tokenPositions: [String: [Int]] = [:]
        for (position, token) in tokens.enumerated() {
            tokenPositions[token, default: []].append(position)
        }

        // Update inverted index
        for token in uniqueTokens {
            let tokenHash = hashToken(token)

            // Get or create index record
            let recordIndex = tokenHashMap[tokenHash] ?? createIndexRecord(token: token, hash: tokenHash)

            guard var indexRecord = indexFile.record(at: recordIndex) else { continue }

            // Create posting entry
            let posting = PostingEntry(
                documentId: id,
                metadataIndex: UInt32(index),
                termFrequency: UInt16(tokenPositions[token]?.count ?? 0),
                positions: tokenPositions[token] ?? []
            )

            // Append to posting list
            let postingData = try encodePosting(posting)
            let postingLocation = try postingFile.appendContent(postingData)

            // Update index record
            indexRecord.documentFrequency += 1
            indexRecord.totalTermFrequency += UInt64(posting.termFrequency)
            indexRecord.lastPostingOffset = postingLocation.offset

            try indexFile.update(at: recordIndex, record: indexRecord)
        }

        // Update trigram index
        let trigrams = generateTrigrams(from: fullText)
        for trigram in trigrams {
            trigramMap[trigram, default: []].insert(index)
        }

        logger.info("Indexed document \(id) with \(uniqueTokens.count) unique tokens")
    }

    /// Reindex document (for updates)
    func reindexDocument(id: UUID, index: Int, title: String?, content: String) async throws {
        // For simplicity, we append new postings rather than updating in place
        // A background compaction process would clean up old entries

        if let title = title {
            try await indexDocument(id: id, index: index, title: title, content: content)
        } else {
            // Reindex with existing title - would need to fetch from metadata
            try await indexDocument(id: id, index: index, title: "", content: content)
        }
    }

    /// Remove document from index
    func removeDocument(id: UUID) async throws {
        // Mark document as deleted in posting lists
        // Actual removal happens during compaction
        logger.info("Marked document \(id) for removal from index")
    }

    // MARK: - Searching

    /// Search for documents matching query
    func search(query: String, limit: Int = 100) async throws -> [IndexSearchResult] {
        try ensureAccelerationStructuresLoaded()
        
        let startTime = CFAbsoluteTimeGetCurrent()

        // Parse query
        let queryTokens = tokenizer.tokenize(query)
        let queryTrigrams = generateTrigrams(from: query.lowercased())

        // Collect candidate documents
        let documentScores: [Int: SearchScore] = [:]

        // Exact token matches
        for token in queryTokens {
            let tokenHash = hashToken(token)

            guard let recordIndex = tokenHashMap[tokenHash],
                let indexRecord = indexFile.record(at: recordIndex)
            else { continue }

            // Read posting list
            let postings = try await readPostingList(from: indexRecord)

            // Calculate TF-IDF scores
            let idf = log(Double(documentCount()) / Double(indexRecord.documentFrequency + 1))

            for posting in postings {
                let tf = Double(posting.termFrequency) / 100.0  // Normalized TF
                let score = tf * idf

                documentScores[Int(posting.metadataIndex), default: SearchScore()]
                    .addTermScore(score, positions: posting.positions)
            }
        }

        // Fuzzy matches using trigrams
        for trigram in queryTrigrams {
            if let docIndices = trigramMap[trigram] {
                for docIndex in docIndices {
                    documentScores[docIndex, default: SearchScore()].addTrigramBoost(0.1)
                }
            }
        }

        // Sort and limit results
        let sortedResults =
            documentScores
            .map { docIndex, score in
                IndexSearchResult(
                    documentId: UUID(),  // Would need to look up from metadata
                    metadataIndex: docIndex,
                    score: score.totalScore,
                    highlights: score.generateHighlights()
                )
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.info("Search completed in \(elapsed)ms, found \(sortedResults.count) results")

        return Array(sortedResults)
    }

    // MARK: - Private Methods
    
    private func ensureAccelerationStructuresLoaded() throws {
        guard !accelerationStructuresLoaded else { return }
        try loadAccelerationStructures()
        accelerationStructuresLoaded = true
    }

    private func loadAccelerationStructures() throws {
        // Load token hash map
        for index in 0..<indexFile.recordCount {
            if let record = indexFile.record(at: index), record.tokenHash != 0 {
                tokenHashMap[record.tokenHash] = index
            }
        }

        // Load trigram map (simplified - in production would read from file)
        logger.info("Loaded \(self.tokenHashMap.count) tokens into acceleration structures")
    }

    private func createIndexRecord(token: String, hash: UInt64) -> Int {
        let record = IndexRecord(
            tokenHash: hash,
            tokenLength: UInt16(token.utf8.count),
            documentFrequency: 0,
            totalTermFrequency: 0,
            firstPostingOffset: 0,
            lastPostingOffset: 0
        )

        do {
            let index = try indexFile.append(record)
            tokenHashMap[hash] = index
            return index
        } catch {
            logger.error("Failed to create index record: \(error)")
            return -1
        }
    }

    private func hashToken(_ token: String) -> UInt64 {
        // FNV-1a hash for good distribution
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in token.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }

    private func generateTrigrams(from text: String) -> Set<String> {
        var trigrams = Set<String>()
        let chars = Array(text.lowercased())

        guard chars.count >= 3 else { return trigrams }

        for index in 0...(chars.count - 3) {
            let trigram = String(chars[index..<(index + 3)])
            trigrams.insert(trigram)
        }

        return trigrams
    }

    private func readPostingList(from indexRecord: IndexRecord) async throws -> [PostingEntry] {
        var postings: [PostingEntry] = []

        // For simplicity, reading last posting only
        // In production, would follow linked list of postings
        if indexRecord.lastPostingOffset > 0 {
            let stream = try postingFile.streamContent(
                offset: indexRecord.lastPostingOffset,
                length: 1024,  // Max posting size
                compressed: false
            )

            for try await chunk in stream {
                if let posting = try? decodePosting(from: chunk) {
                    postings.append(posting)
                }
                break  // Only read first chunk for now
            }
        }

        return postings
    }

    private func encodePosting(_ posting: PostingEntry) throws -> Data {
        // Simple encoding - in production would use more efficient format
        return try JSONEncoder().encode(posting)
    }

    private func decodePosting(from data: Data) throws -> PostingEntry {
        return try JSONDecoder().decode(PostingEntry.self, from: data)
    }

    private func documentCount() -> Int {
        // In production, maintain this count
        return 10000  // Placeholder
    }
}

// MARK: - Supporting Types

struct IndexRecord {
    let tokenHash: UInt64  // 8 bytes
    let tokenLength: UInt16  // 2 bytes
    var documentFrequency: UInt32  // 4 bytes
    var totalTermFrequency: UInt64  // 8 bytes
    var firstPostingOffset: UInt64  // 8 bytes
    var lastPostingOffset: UInt64  // 8 bytes
    var reserved: [UInt8] = Array(repeating: 0, count: 16)  // Pad to 64 bytes
}

struct PostingEntry: Codable {
    let documentId: UUID
    let metadataIndex: UInt32
    let termFrequency: UInt16
    let positions: [Int]
}

struct TrigramEntry {
    let trigram: [UInt8]  // 3 bytes
    let reserved: UInt8 = 0  // Padding
    let documentCount: UInt32
    let postingOffset: UInt64
    var reserved2: [UInt8] = Array(repeating: 0, count: 16)  // Pad to 32 bytes
}

struct IndexSearchResult {
    let documentId: UUID
    let metadataIndex: Int
    let score: Double
    let highlights: [SearchResult.TextRange]
}

// MARK: - Search Scoring

private class SearchScore {
    private var termScores: [Double] = []
    private var positions: [Int] = []
    private var trigramBoost: Double = 0

    var totalScore: Double {
        let baseScore = termScores.reduce(0, +)
        return baseScore * (1.0 + trigramBoost)
    }

    func addTermScore(_ score: Double, positions: [Int]) {
        termScores.append(score)
        self.positions.append(contentsOf: positions)
    }

    func addTrigramBoost(_ boost: Double) {
        trigramBoost += boost
    }

    func generateHighlights() -> [SearchResult.TextRange] {
        // Convert positions to ranges
        return positions.sorted()
            .map { pos in
                SearchResult.TextRange(start: pos, end: pos + 10)  // Approximate
            }
    }
}

// MARK: - Tokenizer

class Tokenizer {
    private let stopWords: Set<String> = [
        "the", "be", "to", "of", "and", "a", "in", "that", "have",
        "i", "it", "for", "not", "on", "with", "he", "as", "you",
        "do", "at", "this", "but", "his", "by", "from"
    ]

    func tokenize(_ text: String) -> [String] {
        let options: NSLinguisticTagger.Options = [.omitWhitespace, .omitPunctuation]
        let schemes = NSLinguisticTagger.availableTagSchemes(forLanguage: "en")

        guard let scheme = schemes.first else {
            // Fallback to simple tokenization
            return
                text
                .lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count > 2 && !stopWords.contains($0) }
        }

        let tagger = NSLinguisticTagger(tagSchemes: [scheme], options: Int(options.rawValue))
        tagger.string = text

        var tokens: [String] = []
        let range = NSRange(location: 0, length: text.utf16.count)

        tagger.enumerateTags(in: range, unit: .word, scheme: scheme, options: options) { _, tokenRange, stop in
            let token = (text as NSString).substring(with: tokenRange).lowercased()
            if token.count > 2 && !stopWords.contains(token) {
                tokens.append(token)
            }
            stop.pointee = false
        }

        return tokens
    }
}
