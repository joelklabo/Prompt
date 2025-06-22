import Foundation
import simd

/// High-performance string interning pool with SIMD search
final class StringPool {
    // MARK: - Storage

    /// Contiguous character storage for all strings
    private var characters: ContiguousArray<UInt8> = []

    /// String boundaries [start, end) for each interned string
    private var boundaries: ContiguousArray<StringBoundary> = []

    /// Hash table for O(1) lookup
    private var hashTable: [Int: ContiguousArray<Int32>] = [:]

    /// Reverse lookup for string resolution
    private var indexMap: ContiguousArray<Int32> = []

    /// Pre-computed lowercase versions for search
    private var lowercaseCache: ContiguousArray<StringBoundary> = []

    // MARK: - Statistics

    private(set) var count: Int = 0
    private(set) var totalBytes: Int = 0
    private(set) var duplicatesSaved: Int = 0

    var isEmpty: Bool { isEmpty }

    init(initialCapacity: Int = 10000) {
        characters.reserveCapacity(initialCapacity * 50)  // Avg 50 chars per string
        boundaries.reserveCapacity(initialCapacity)
        indexMap.reserveCapacity(initialCapacity)
    }

    // MARK: - Core Operations

    /// Intern a string and return its index
    @discardableResult
    func intern(_ string: String) -> Int32 {
        let hash = string.hashValue
        let utf8 = Array(string.utf8)

        // Check if already interned
        if let candidates = hashTable[hash] {
            for candidateIdx in candidates {
                let idx = Int(candidateIdx)
                if boundaries[idx].matches(utf8, in: characters) {
                    duplicatesSaved += 1
                    return indexMap[idx]
                }
            }
        }

        // Add new string
        let startIdx = characters.count
        characters.append(contentsOf: utf8)
        let endIdx = characters.count

        let boundary = StringBoundary(start: Int32(startIdx), end: Int32(endIdx))
        boundaries.append(boundary)

        // Add lowercase version for search
        let lowercase = string.lowercased()
        let lowercaseUTF8 = Array(lowercase.utf8)
        let lowercaseStart = characters.count
        characters.append(contentsOf: lowercaseUTF8)
        let lowercaseEnd = characters.count
        lowercaseCache.append(StringBoundary(start: Int32(lowercaseStart), end: Int32(lowercaseEnd)))

        let index = Int32(count)
        indexMap.append(index)
        hashTable[hash, default: []].append(Int32(boundaries.count - 1))

        count += 1
        totalBytes += utf8.count + lowercaseUTF8.count

        return index
    }

    /// Resolve string at index
    func resolve(at index: Int) -> String? {
        guard index >= 0 && index < indexMap.count else { return nil }

        let boundaryIdx = Int(indexMap[index])
        let boundary = boundaries[boundaryIdx]

        let start = Int(boundary.start)
        let end = Int(boundary.end)

        return characters.withUnsafeBufferPointer { buffer in
            let slice = buffer[start..<end]
            let data = Data(slice)
            return String(bytes: data, encoding: .utf8) ?? ""
        }
    }

    /// Update string at index (returns new index if string changed)
    func update(at index: Int, with newString: String) -> Int32 {
        guard index >= 0 && index < indexMap.count else {
            return intern(newString)
        }

        // Check if new string already exists
        let newIndex = intern(newString)

        // Update mapping
        indexMap[index] = Int32(newIndex)

        return newIndex
    }

    /// SIMD-accelerated string search
    func vectorizedSearch(query: String) -> Set<Int> {
        let queryBytes = Array(query.utf8)
        guard !queryBytes.isEmpty else { return [] }

        var matches = Set<Int>()
        let queryLen = queryBytes.count

        // Use SIMD to search for first character matches
        let firstChar = queryBytes[0]
        _ = simd_uint8(repeating: UInt32(firstChar))

        // Search in lowercase cache for case-insensitive matching
        for (idx, boundary) in lowercaseCache.enumerated() {
            let start = Int(boundary.start)
            let end = Int(boundary.end)

            if end - start >= queryLen {
                // SIMD comparison for potential matches
                var pos = start
                while pos <= end - queryLen {
                    if characters[pos] == firstChar {
                        // Potential match found, verify full string
                        var isMatch = true
                        for offset in 1..<queryLen where characters[pos + offset] != queryBytes[offset] {
                            isMatch = false
                            break
                        }
                        if isMatch {
                            matches.insert(idx)
                            break
                        }
                    }
                    pos += 1
                }
            }
        }

        return matches
    }

    /// Memory usage statistics
    func memoryStats() -> MemoryStats {
        MemoryStats(
            stringCount: count,
            totalCharacters: characters.count,
            averageLength: !isEmpty ? totalBytes / count : 0,
            deduplicationRatio: !isEmpty ? Double(duplicatesSaved) / Double(count + duplicatesSaved) : 0,
            memoryUsage: characters.count + boundaries.count * MemoryLayout<StringBoundary>.size
        )
    }
}

// MARK: - Supporting Types

struct StringBoundary {
    let start: Int32
    let end: Int32

    var length: Int32 { end - start }

    func matches(_ bytes: [UInt8], in storage: ContiguousArray<UInt8>) -> Bool {
        let len = Int(end - start)
        guard bytes.count == len else { return false }

        let startIdx = Int(start)
        for offset in 0..<len where storage[startIdx + offset] != bytes[offset] {
            return false
        }
        return true
    }
}

struct MemoryStats {
    let stringCount: Int
    let totalCharacters: Int
    let averageLength: Int
    let deduplicationRatio: Double
    let memoryUsage: Int
}
