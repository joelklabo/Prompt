import Foundation
import os
import simd

/// Bit-packed array for storing small values efficiently
final class BitPackedArray {
    private let logger = Logger(subsystem: "com.prompt.app", category: "BitPackedArray")
    private var storage: ContiguousArray<UInt64> = []
    private var count: Int = 0
    private let bitsPerValue: Int = 2  // For categories (4 values)
    private let valuesPerWord: Int = 32  // 64 bits / 2 bits

    init() {
        storage.reserveCapacity(1000)
    }

    func append(_ value: UInt8) {
        let wordIndex = count / valuesPerWord
        let bitOffset = (count % valuesPerWord) * bitsPerValue

        // Ensure we have enough storage
        while storage.count <= wordIndex {
            storage.append(0)
        }

        // Clear existing bits and set new value
        let mask = UInt64(0b11) << bitOffset
        storage[wordIndex] = (storage[wordIndex] & ~mask) | (UInt64(value & 0b11) << bitOffset)

        count += 1
    }

    subscript(index: Int) -> UInt8 {
        get {
            guard index >= 0 && index < count else { return 0 }

            let wordIndex = index / valuesPerWord
            let bitOffset = (index % valuesPerWord) * bitsPerValue

            return UInt8((storage[wordIndex] >> bitOffset) & 0b11)
        }
        set {
            guard index >= 0 && index < count else { return }

            let wordIndex = index / valuesPerWord
            let bitOffset = (index % valuesPerWord) * bitsPerValue

            let mask = UInt64(0b11) << bitOffset
            storage[wordIndex] = (storage[wordIndex] & ~mask) | (UInt64(newValue & 0b11) << bitOffset)
        }
    }

    /// SIMD-optimized counting of each category
    func vectorizedCount(into result: inout simd_int4) {
        result = simd_int4(repeating: 0)

        // Process 32 values at a time using bit manipulation
        for word in storage {
            var workingWord = word
            for _ in 0..<valuesPerWord {
                let category = Int(workingWord & 0b11)
                result[category] += 1
                workingWord >>= 2
            }
        }

        // Adjust for partial last word
        let fullWords = count / valuesPerWord
        let processedCount = fullWords * valuesPerWord
        let excess = processedCount + valuesPerWord - count

        if excess > 0 && fullWords < storage.count {
            // Subtract the extra counted values from the last partial word
            var lastWord = storage[fullWords]
            for _ in 0..<excess {
                lastWord >>= 2
                let category = Int(lastWord & 0b11)
                result[category] -= 1
            }
        }
    }
}

/// Bit-packed metadata storage
final class BitPackedMetadata {
    private var storage: ContiguousArray<UInt32> = []

    func append(_ metadata: MetadataBits) {
        storage.append(metadata.packed)
    }

    func unpack(at index: Int) -> PromptMetadata {
        guard index >= 0 && index < storage.count else {
            return PromptMetadata()
        }

        let bits = storage[index]
        let metadata = PromptMetadata()

        metadata.isFavorite = (bits & 0x1) != 0
        metadata.viewCount = Int((bits >> 16) & 0xFFFF)

        if (bits & 0x2) != 0 {
            // Has short link - would need separate storage for actual code
            metadata.shortCode = "cached"  // Placeholder
        }

        return metadata
    }

    subscript(index: Int) -> MetadataBits {
        get {
            guard index >= 0 && index < storage.count else {
                return MetadataBits()
            }
            return MetadataBits(packed: storage[index])
        }
        set {
            guard index >= 0 && index < storage.count else { return }
            storage[index] = newValue.packed
        }
    }

    /// Count favorites using SIMD
    func countFavorites() -> Int {
        var count = 0

        // Process 16 values at a time using SIMD
        let simdCount = storage.count / 16

        storage.withUnsafeBufferPointer { buffer in
            for index in 0..<simdCount {
                let offset = index * 16

                // Load 16 UInt32 values
                let v1 = simd_uint16(
                    buffer[offset], buffer[offset + 1], buffer[offset + 2], buffer[offset + 3],
                    buffer[offset + 4], buffer[offset + 5], buffer[offset + 6], buffer[offset + 7],
                    buffer[offset + 8], buffer[offset + 9], buffer[offset + 10], buffer[offset + 11],
                    buffer[offset + 12], buffer[offset + 13], buffer[offset + 14], buffer[offset + 15]
                )

                // Extract favorite bits (bit 0)
                let favorites = v1 & 0x1

                // Count set bits
                // Count the number of true values in the SIMD vector
                for index in 0..<16 where favorites[index] != 0 {
                    count += 1
                }
            }
        }

        // Handle remaining elements
        for index in (simdCount * 16)..<storage.count where (storage[index] & 0x1) != 0 {
            count += 1
        }

        return count
    }
}

/// Memory-mapped backing store for persistence
final class BitPackedMemoryMappedStore {
    private let logger = Logger(subsystem: "com.prompt.app", category: "BitPackedMemoryMappedStore")
    private let url: URL
    private var fileHandle: FileHandle?
    private var mappedData: Data?

    init(url: URL) {
        self.url = url
        setupMapping()
    }

    private func setupMapping() {
        do {
            // Create file if it doesn't exist
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }

            fileHandle = try FileHandle(forUpdating: url)

            // Memory map the file
            if let handle = fileHandle {
                let size = try handle.seekToEnd()
                if size > 0 {
                    try handle.seek(toOffset: 0)
                    // For now, just read the data normally
                    // TODO: Implement proper memory mapping
                    mappedData = try handle.readToEnd()
                }
            }
        } catch {
            // Fallback to regular file I/O
            logger.error("Memory mapping failed: \(error)")
        }
    }

    func read(offset: Int, length: Int) -> Data? {
        guard let data = mappedData,
            offset >= 0,
            offset + length <= data.count
        else {
            return nil
        }

        return data.subdata(in: offset..<(offset + length))
    }

    func write(data: Data, at offset: Int) {
        guard let handle = fileHandle else { return }

        do {
            try handle.seek(toOffset: UInt64(offset))
            handle.write(data)

            // Update mapped data
            if offset + data.count > (mappedData?.count ?? 0) {
                setupMapping()  // Remap with new size
            }
        } catch {
            logger.error("Write failed: \(error)")
        }
    }

    func sync() {
        fileHandle?.synchronizeFile()
    }

    deinit {
        sync()
        try? fileHandle?.close()
    }
}

/// Version pool for efficient version storage
final class VersionPool {
    private var versions: ContiguousArray<VersionData> = []

    func append(_ version: VersionData) -> Int32 {
        let index = Int32(versions.count)
        versions.append(version)
        return index
    }

    func fetch(range: VersionRange) -> [VersionData] {
        guard range.start >= 0 && !range.isEmpty else { return [] }

        let start = Int(range.start)
        let end = min(start + Int(range.count), versions.count)

        return Array(versions[start..<end])
    }
}

struct VersionData {
    let versionNumber: Int
    let title: String
    let content: String
    let createdAt: Date
    let changeDescription: String?
}

/// AI analysis pool
final class AIAnalysisPool {
    private var analyses: ContiguousArray<AIAnalysisData> = []

    func store(_ analysis: AIAnalysisData) -> Int32 {
        let index = Int32(analyses.count)
        analyses.append(analysis)
        return index
    }

    func fetch(_ index: Int) -> AIAnalysisData? {
        guard index >= 0 && index < analyses.count else { return nil }
        return analyses[index]
    }
}

struct AIAnalysisData {
    let suggestedTags: [String]
    let category: Category
    let categoryConfidence: Double
    let summary: String?
    let enhancementSuggestions: [String]
    let relatedPromptIDs: [UUID]
    let analyzedAt: Date
}
