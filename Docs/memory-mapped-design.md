# Memory-Mapped File Architecture for Prompt Storage

## Overview

This document describes a memory-mapped file approach to address performance issues with large markdown strings in the Prompt application. The design leverages `mmap` for efficient large file access, implements custom indexing structures, and provides fast random access while minimizing memory footprint.

## Current Issues Analysis

### Performance Bottlenecks
1. **SwiftData String Storage**: Large markdown content stored as String properties causes:
   - High memory usage (UTF-16 encoding doubles size)
   - Slow fetch operations when loading multiple prompts
   - Memory pressure with document sets > 1000 prompts

2. **String Interning Pool**: Current `StringPool` implementation:
   - Keeps all strings in memory
   - SIMD search still requires full string comparison
   - No efficient partial loading

3. **Compression Overhead**: `CompressedTextStorage`:
   - Decompression latency affects UI responsiveness
   - LRU cache limited to 100 items
   - Full decompression required for search

## Memory-Mapped Architecture

### File Structure

```
prompt-store/
├── metadata.idx      # Prompt metadata index (mmap'd)
├── content.dat       # Content storage file (mmap'd)
├── search.idx        # Search index (mmap'd)
├── stringpool.dat    # String pool data (mmap'd)
└── catalog.json      # File catalog and versioning
```

### 1. Metadata Index File (`metadata.idx`)

Binary format with fixed-size records for O(1) access:

```swift
struct MetadataRecord {
    // Fixed size: 256 bytes
    let promptId: UUID           // 16 bytes
    let contentOffset: UInt64    // 8 bytes - offset in content.dat
    let contentLength: UInt32    // 4 bytes - length in bytes
    let compressedLength: UInt32 // 4 bytes - 0 if uncompressed
    let titleOffset: UInt32      // 4 bytes - offset in stringpool
    let titleLength: UInt16      // 2 bytes
    let category: UInt8          // 1 byte
    let flags: UInt8             // 1 byte (favorite, deleted, etc)
    let createdAt: Int64         // 8 bytes - timestamp
    let modifiedAt: Int64        // 8 bytes - timestamp
    let viewCount: UInt32        // 4 bytes
    let copyCount: UInt32        // 4 bytes
    let tagCount: UInt16         // 2 bytes
    let reserved: [UInt8]        // 194 bytes - future use
}
```

### 2. Content Data File (`content.dat`)

Variable-length content storage with alignment:

```swift
struct ContentBlock {
    let magic: UInt32         // 0xC0FFEE42 - validity check
    let checksum: UInt32      // CRC32 checksum
    let encoding: UInt8       // 0=UTF8, 1=UTF16, 2=compressed
    let reserved: [UInt8]     // 7 bytes padding
    let data: [UInt8]         // Variable length content
    // Padded to 16-byte alignment
}
```

### 3. Search Index File (`search.idx`)

Inverted index with posting lists:

```swift
struct SearchIndexHeader {
    let version: UInt32
    let tokenCount: UInt32
    let documentCount: UInt32
    let postingListOffset: UInt64
    let trigramIndexOffset: UInt64
}

struct TokenEntry {
    let tokenHash: UInt64        // FNV-1a hash
    let documentFrequency: UInt32
    let postingListOffset: UInt64
    let postingListSize: UInt32
}

struct PostingList {
    // Delta-encoded document IDs with position info
    let docId: VarInt           // Variable-length integer
    let positions: [VarInt]     // Token positions in document
}
```

### 4. String Pool File (`stringpool.dat`)

Deduplicated string storage:

```swift
struct StringPoolHeader {
    let version: UInt32
    let stringCount: UInt32
    let totalSize: UInt64
    let hashTableOffset: UInt64
}

struct StringEntry {
    let hash: UInt64
    let offset: UInt64
    let length: UInt32
    let refCount: UInt32
}
```

## Implementation Approach

### Memory Mapping Manager

```swift
actor MemoryMappedStore {
    private var metadataFile: MappedFile<MetadataRecord>
    private var contentFile: MappedFile<UInt8>
    private var searchIndex: MappedSearchIndex
    private var stringPool: MappedStringPool
    
    init(directory: URL) async throws {
        // Initialize memory-mapped files
        metadataFile = try MappedFile(
            url: directory.appendingPathComponent("metadata.idx"),
            recordSize: 256
        )
        
        contentFile = try MappedFile(
            url: directory.appendingPathComponent("content.dat"),
            recordSize: 1  // Byte-level access
        )
        
        searchIndex = try MappedSearchIndex(
            url: directory.appendingPathComponent("search.idx")
        )
        
        stringPool = try MappedStringPool(
            url: directory.appendingPathComponent("stringpool.dat")
        )
    }
    
    // Fast metadata access
    func getMetadata(at index: Int) -> MetadataRecord? {
        return metadataFile.record(at: index)
    }
    
    // Efficient content streaming
    func streamContent(at offset: UInt64, length: UInt32) -> AsyncStream<Data> {
        AsyncStream { continuation in
            Task {
                let chunkSize = 64 * 1024 // 64KB chunks
                var position = offset
                let endPosition = offset + UInt64(length)
                
                while position < endPosition {
                    let size = min(chunkSize, Int(endPosition - position))
                    if let chunk = contentFile.readBytes(at: position, count: size) {
                        continuation.yield(Data(chunk))
                        position += UInt64(size)
                    } else {
                        break
                    }
                }
                continuation.finish()
            }
        }
    }
}
```

### Platform-Specific Memory Mapping

```swift
class MappedFile<T> {
    private let fileHandle: FileHandle
    private let memoryMap: UnsafeMutableRawPointer
    private let size: Int
    
    init(url: URL, recordSize: Int) throws {
        // Open file
        fileHandle = try FileHandle(forUpdating: url)
        
        // Get file size
        let fileSize = try fileHandle.seekToEnd()
        fileHandle.seek(toFileOffset: 0)
        
        // Memory map the file
        let fd = fileHandle.fileDescriptor
        memoryMap = mmap(
            nil,                    // Let system choose address
            Int(fileSize),         // Size of mapping
            PROT_READ | PROT_WRITE, // Read/write access
            MAP_SHARED,            // Share with other processes
            fd,                    // File descriptor
            0                      // Offset
        )
        
        guard memoryMap != MAP_FAILED else {
            throw MMapError.mappingFailed(errno)
        }
        
        self.size = Int(fileSize)
        
        // Advise kernel about access pattern
        madvise(memoryMap, size, MADV_RANDOM) // Random access expected
    }
    
    deinit {
        munmap(memoryMap, size)
        try? fileHandle.close()
    }
    
    func record(at index: Int) -> T? {
        let recordSize = MemoryLayout<T>.size
        let offset = index * recordSize
        
        guard offset + recordSize <= size else { return nil }
        
        return memoryMap.advanced(by: offset).bindMemory(
            to: T.self,
            capacity: 1
        ).pointee
    }
}
```

### Concurrent Access Safety

```swift
actor ConcurrentAccessManager {
    private var readLocks: [UUID: Int] = [:] // Reference counting
    private var writeLock: UUID?
    
    func acquireReadLock(for id: UUID) async {
        while writeLock != nil {
            await Task.yield()
        }
        readLocks[id, default: 0] += 1
    }
    
    func releaseReadLock(for id: UUID) {
        if let count = readLocks[id], count > 1 {
            readLocks[id] = count - 1
        } else {
            readLocks.removeValue(forKey: id)
        }
    }
    
    func acquireWriteLock(for id: UUID) async {
        while writeLock != nil || !readLocks.isEmpty {
            await Task.yield()
        }
        writeLock = id
    }
    
    func releaseWriteLock(for id: UUID) {
        if writeLock == id {
            writeLock = nil
        }
    }
}
```

### Crash Resilience

```swift
struct TransactionLog {
    enum Operation {
        case insert(promptId: UUID, offset: UInt64, length: UInt32)
        case update(promptId: UUID, oldOffset: UInt64, newOffset: UInt64, newLength: UInt32)
        case delete(promptId: UUID, offset: UInt64, length: UInt32)
    }
    
    private let logFile: FileHandle
    
    func beginTransaction() throws -> TransactionID {
        let txId = TransactionID()
        let header = TransactionHeader(
            id: txId,
            timestamp: Date(),
            status: .pending
        )
        try logFile.write(contentsOf: header.encoded())
        return txId
    }
    
    func logOperation(_ op: Operation, txId: TransactionID) throws {
        let entry = LogEntry(transactionId: txId, operation: op)
        try logFile.write(contentsOf: entry.encoded())
    }
    
    func commitTransaction(_ txId: TransactionID) throws {
        let footer = TransactionFooter(
            id: txId,
            status: .committed,
            checksum: calculateChecksum()
        )
        try logFile.write(contentsOf: footer.encoded())
        try logFile.synchronize() // fsync
    }
}
```

## Performance Characteristics

### Current Approach (SwiftData)
- **Memory Usage**: O(n) where n = total content size
- **Load Time**: O(n) for fetching all prompts
- **Search Time**: O(n*m) where m = query length
- **Update Time**: O(1) but requires full object load

### Memory-Mapped Approach
- **Memory Usage**: O(1) + page cache (managed by OS)
- **Load Time**: O(1) for metadata, O(k) for content where k = viewed content
- **Search Time**: O(log n) with index, O(d) where d = matching documents
- **Update Time**: O(1) for metadata, O(c) for content where c = content size

## iOS/macOS Platform Considerations

### iOS Constraints
1. **Memory Limits**: 
   - Foreground app: ~2GB on modern devices
   - Background: Much lower (~30MB)
   - Use `vm_page_size` for optimal mapping

2. **File Protection**:
   ```swift
   try FileManager.default.setAttributes([
       .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
   ], ofItemAtPath: filePath)
   ```

3. **Background Handling**:
   ```swift
   func applicationDidEnterBackground() {
       // Sync any pending writes
       msync(memoryMap, size, MS_ASYNC)
       // Advise kernel we won't need pages soon
       madvise(memoryMap, size, MADV_DONTNEED)
   }
   ```

### macOS Optimizations
1. **Larger Page Sizes**: Use `vm_page_size` (typically 16KB on Apple Silicon)
2. **Prefetching**: More aggressive with `madvise(MADV_WILLNEED)`
3. **Memory Pressure**: Register for memory pressure notifications

## Migration Strategy

1. **Parallel Operation**: Keep SwiftData operational during migration
2. **Background Migration**: 
   ```swift
   func migrateToMemoryMapped() async {
       let prompts = try await fetchAllPrompts()
       for batch in prompts.chunked(into: 100) {
           try await memoryMappedStore.importBatch(batch)
           await Task.yield() // Keep UI responsive
       }
   }
   ```

3. **Verification**: CRC32 checksums for data integrity
4. **Rollback**: Keep SwiftData until migration verified

## Code Examples

### Reading a Prompt

```swift
extension MemoryMappedStore {
    func readPrompt(id: UUID) async throws -> PromptDetail {
        // Find metadata record
        guard let index = await findMetadataIndex(for: id),
              let metadata = metadataFile.record(at: index) else {
            throw PromptError.notFound(id)
        }
        
        // Read title from string pool
        let title = await stringPool.getString(
            offset: metadata.titleOffset,
            length: metadata.titleLength
        )
        
        // Stream content
        var content = ""
        for await chunk in streamContent(
            at: metadata.contentOffset,
            length: metadata.contentLength
        ) {
            content.append(String(data: chunk, encoding: .utf8) ?? "")
        }
        
        return PromptDetail(
            id: id,
            title: title,
            content: content,
            category: Category(rawValue: metadata.category),
            createdAt: Date(timeIntervalSince1970: TimeInterval(metadata.createdAt)),
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(metadata.modifiedAt))
        )
    }
}
```

### Searching Prompts

```swift
extension MemoryMappedStore {
    func search(query: String) async -> [SearchResult] {
        // Tokenize query
        let tokens = Tokenizer.tokenize(query)
        
        // Get posting lists from index
        var documentScores: [UUID: Double] = [:]
        
        for token in tokens {
            if let postings = await searchIndex.getPostings(for: token) {
                for posting in postings {
                    documentScores[posting.documentId, default: 0] += posting.score
                }
            }
        }
        
        // Sort by score and fetch metadata
        let sortedDocs = documentScores.sorted { $0.value > $1.value }
        
        return sortedDocs.prefix(100).compactMap { docId, score in
            guard let metadata = await getMetadata(for: docId) else { return nil }
            return SearchResult(
                promptId: docId,
                score: score,
                highlights: [] // Calculate separately if needed
            )
        }
    }
}
```

### Writing a Prompt

```swift
extension MemoryMappedStore {
    func writePrompt(_ prompt: PromptCreateRequest) async throws -> UUID {
        let promptId = UUID()
        let txId = try await transactionLog.beginTransaction()
        
        do {
            // Write content
            let contentOffset = await contentFile.append(prompt.content.data(using: .utf8)!)
            
            // Add to string pool
            let titleOffset = await stringPool.intern(prompt.title)
            
            // Create metadata record
            let metadata = MetadataRecord(
                promptId: promptId,
                contentOffset: contentOffset,
                contentLength: UInt32(prompt.content.utf8.count),
                titleOffset: titleOffset.offset,
                titleLength: UInt16(titleOffset.length),
                // ... other fields
            )
            
            // Write metadata
            let metadataIndex = await metadataFile.append(metadata)
            
            // Update search index
            await searchIndex.indexDocument(
                id: promptId,
                title: prompt.title,
                content: prompt.content
            )
            
            // Commit transaction
            try await transactionLog.commitTransaction(txId)
            
            return promptId
        } catch {
            try await transactionLog.rollbackTransaction(txId)
            throw error
        }
    }
}
```

## Performance Benchmarks (Expected)

| Operation | Current (SwiftData) | Memory-Mapped | Improvement |
|-----------|-------------------|---------------|-------------|
| Load 10K prompts metadata | 2.5s | 15ms | 166x |
| Search 10K prompts | 450ms | 25ms | 18x |
| Open large prompt (10MB) | 180ms | 5ms | 36x |
| Memory usage (10K prompts) | 512MB | 45MB | 11x less |
| Cold start | 3.2s | 0.8s | 4x |

## Conclusion

The memory-mapped file approach provides significant performance improvements while maintaining data integrity and supporting concurrent access. The architecture is designed to scale to millions of prompts while keeping memory usage constant and providing sub-millisecond access times for common operations.