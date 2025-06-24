import Compression
import Foundation
import os

/// Generic memory-mapped file with type-safe record access
class MappedFile<T> {
    private let fileHandle: FileHandle
    private var memoryMap: UnsafeMutableRawPointer
    private var fileSize: Int
    private let recordSize: Int
    private let logger = Logger(subsystem: "com.prompt.app", category: "MappedFile")

    /// Number of records that can fit in the current file
    var recordCount: Int {
        fileSize / recordSize
    }

    init(url: URL, initialSize: Int = 0) throws {
        self.recordSize = MemoryLayout<T>.stride  // Use stride for proper alignment

        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)

            // Pre-allocate space if initial size specified
            if initialSize > 0 {
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: UInt64(initialSize))
                try handle.close()
            }
        }

        // Open file for read/write
        fileHandle = try FileHandle(forUpdating: url)

        // Get current file size
        let fileSize = try fileHandle.seekToEnd()
        self.fileSize = Int(fileSize)

        // Ensure file has at least one page
        let pageSize = 4096  // Use standard page size
        let minSize = max(pageSize, recordSize)
        if self.fileSize < minSize {
            try fileHandle.truncate(atOffset: UInt64(minSize))
            self.fileSize = minSize
        }

        fileHandle.seek(toFileOffset: 0)

        // Memory map the file
        let fd = fileHandle.fileDescriptor
        memoryMap = mmap(
            nil,  // Let system choose address
            self.fileSize,  // Size of mapping
            PROT_READ | PROT_WRITE,  // Read/write access
            MAP_SHARED,  // Share with other processes
            fd,  // File descriptor
            0  // Offset from start
        )

        guard memoryMap != MAP_FAILED else {
            let error = errno
            throw MMapError.mappingFailed(error, String(cString: strerror(error)))
        }

        // Advise kernel about access pattern
        let adviseResult = madvise(memoryMap, self.fileSize, MADV_RANDOM)
        if adviseResult != 0 {
            logger.warning("madvise failed: \(errno)")
        }

        logger.info("Mapped file at \(url.path), size: \(self.fileSize) bytes")
    }

    deinit {
        // Sync any pending changes
        msync(memoryMap, fileSize, MS_SYNC)

        // Unmap the file
        munmap(memoryMap, fileSize)

        // Close file handle
        try? fileHandle.close()
    }

    /// Get record at index
    func record(at index: Int) -> T? {
        let offset = index * recordSize
        guard offset >= 0 && offset + recordSize <= fileSize else {
            logger.warning("Invalid record index: \(index)")
            return nil
        }

        return memoryMap.advanced(by: offset)
            .bindMemory(
                to: T.self,
                capacity: 1
            )
            .pointee
    }

    /// Update record at index
    func update(at index: Int, record: T) throws {
        let offset = index * recordSize
        guard offset >= 0 && offset + recordSize <= fileSize else {
            throw MMapError.invalidOffset(index)
        }

        memoryMap.advanced(by: offset)
            .bindMemory(
                to: T.self,
                capacity: 1
            )
            .pointee = record

        // Ensure write is persisted
        let syncResult = msync(
            memoryMap.advanced(by: offset),
            recordSize,
            MS_ASYNC  // Async sync for performance
        )

        if syncResult != 0 {
            logger.warning("msync failed for record \(index): \(errno)")
        }
    }

    /// Append new record, growing file if needed
    @discardableResult
    func append(_ record: T) throws -> Int {
        let index = recordCount
        let requiredSize = (index + 1) * recordSize

        // Grow file if needed
        if requiredSize > fileSize {
            try growFile(to: requiredSize)
        }

        try update(at: index, record: record)
        return index
    }

    /// Read multiple records efficiently
    func readBatch(startIndex: Int, count: Int) -> [T] {
        let endIndex = min(startIndex + count, recordCount)
        guard startIndex < endIndex else { return [] }

        var results: [T] = []
        results.reserveCapacity(endIndex - startIndex)

        let startOffset = startIndex * recordSize
        let batchSize = (endIndex - startIndex) * recordSize

        // Advise kernel we'll need this range
        madvise(
            memoryMap.advanced(by: startOffset),
            batchSize,
            MADV_WILLNEED
        )

        for index in startIndex..<endIndex {
            if let record = record(at: index) {
                results.append(record)
            }
        }

        return results
    }

    /// Sync all pending changes to disk
    func sync() throws {
        let result = msync(memoryMap, fileSize, MS_SYNC)
        if result != 0 {
            throw MMapError.syncFailed(errno)
        }
    }

    // MARK: - Private Methods

    private func growFile(to newSize: Int) throws {
        // Calculate new size (grow by at least one page)
        let pageSize = 4096  // Use standard page size
        let alignedSize = ((newSize + pageSize - 1) / pageSize) * pageSize

        logger.info("Growing file from \(self.fileSize) to \(alignedSize) bytes")

        // Unmap current mapping
        munmap(memoryMap, fileSize)

        // Extend file
        try fileHandle.truncate(atOffset: UInt64(alignedSize))

        // Remap with new size
        let fd = fileHandle.fileDescriptor
        let newMap = mmap(
            nil,
            alignedSize,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            fd,
            0
        )

        guard newMap != MAP_FAILED else {
            // Try to restore original mapping
            _ = mmap(memoryMap, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
            throw MMapError.remapFailed(errno)
        }

        // Update instance variables
        memoryMap = newMap!
        fileSize = alignedSize

        // Re-advise access pattern
        madvise(memoryMap, fileSize, MADV_RANDOM)
    }
}

// MARK: - Content-specific mapped file

/// Specialized mapped file for variable-length content storage
class ContentMappedFile {
    private let fileHandle: FileHandle
    private var memoryMap: UnsafeMutableRawPointer!
    private var fileSize: Int
    private var writeOffset: UInt64 = 0
    private let logger = Logger(subsystem: "com.prompt.app", category: "ContentMappedFile")
    private let lock = NSLock()

    init(url: URL, initialSize: Int) throws {
        // Create file if needed
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        fileHandle = try FileHandle(forUpdating: url)

        // Set initial size
        let currentSize = try fileHandle.seekToEnd()
        if currentSize < initialSize {
            try fileHandle.truncate(atOffset: UInt64(initialSize))
        }
        fileSize = max(Int(currentSize), initialSize)

        // Find write offset (scan for last valid block)
        writeOffset = try findWriteOffset()

        fileHandle.seek(toFileOffset: 0)

        // Map the file
        let fd = fileHandle.fileDescriptor
        memoryMap = mmap(nil, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)

        guard memoryMap != MAP_FAILED else {
            throw MMapError.mappingFailed(errno, String(cString: strerror(errno)))
        }

        // Sequential access pattern for content
        madvise(memoryMap, fileSize, MADV_SEQUENTIAL)
    }

    deinit {
        msync(memoryMap, fileSize, MS_SYNC)
        munmap(memoryMap, fileSize)
        try? fileHandle.close()
    }

    /// Append content and return location
    func appendContent(_ data: Data) throws -> ContentLocation {
        lock.lock()
        defer { lock.unlock() }

        let blockSize = data.count + MemoryLayout<ContentBlock>.size
        let alignedSize = ((blockSize + 15) / 16) * 16  // 16-byte alignment

        // Ensure we have space
        if Int(writeOffset) + alignedSize > fileSize {
            let pageSize = Int(getpagesize())
            try growFile(to: Int(writeOffset) + alignedSize + pageSize)
        }

        // Create content block
        let block = ContentBlock(
            magic: 0xC0FF_EE42,
            checksum: data.crc32(),
            encoding: .utf8,
            dataSize: UInt32(data.count)
        )

        // Write header
        let headerPtr = memoryMap.advanced(by: Int(writeOffset))
        headerPtr.bindMemory(to: ContentBlock.self, capacity: 1).pointee = block

        // Write data
        let dataOffset = Int(writeOffset) + MemoryLayout<ContentBlock>.size
        _ = data.withUnsafeBytes { bytes in
            memcpy(memoryMap.advanced(by: dataOffset), bytes.baseAddress!, data.count)
        }

        // Calculate compression if beneficial
        let compressedData = try? (data as NSData).compressed(using: .zlib) as Data
        let useCompression = compressedData != nil && compressedData!.count < Int(Double(data.count) * 0.8)

        let location = ContentLocation(
            offset: writeOffset,
            length: UInt32(data.count),
            compressedLength: useCompression ? UInt32(compressedData!.count) : 0
        )

        // Update write offset
        writeOffset += UInt64(alignedSize)

        // Async sync for performance
        msync(headerPtr, alignedSize, MS_ASYNC)

        return location
    }

    /// Stream content from location
    func streamContent(offset: UInt64, length: UInt32, compressed: Bool) throws -> AsyncThrowingStream<Data, Error> {
        // Read data synchronously before creating the async stream
        let headerPtr = memoryMap.advanced(by: Int(offset))
        let header = headerPtr.bindMemory(to: ContentBlock.self, capacity: 1).pointee
        
        guard header.magic == 0xC0FF_EE42 else {
            throw StorageError.corruptedData
        }
        
        // Read data
        let dataOffset = Int(offset) + MemoryLayout<ContentBlock>.size
        let dataPtr = memoryMap.advanced(by: dataOffset)
        let data = Data(bytes: dataPtr, count: Int(header.dataSize))
        
        // Verify checksum
        guard data.crc32() == header.checksum else {
            throw StorageError.corruptedData
        }
        
        // Decompress if needed
        let finalData: Data =
            compressed ? ((try? (data as NSData).decompressed(using: .zlib) as Data) ?? data) : data
        
        return AsyncThrowingStream { continuation in
            Task { @Sendable in
                // Stream in chunks
                let chunkSize = 64 * 1024  // 64KB chunks
                var position = 0
                
                while position < finalData.count {
                    let endPosition = min(position + chunkSize, finalData.count)
                    let chunk = finalData[position..<endPosition]
                    continuation.yield(chunk)
                    position = endPosition
                }
                
                continuation.finish()
            }
        }
    }

    private func findWriteOffset() throws -> UInt64 {
        // Scan for last valid block
        var offset: UInt64 = 0
        let headerSize = MemoryLayout<ContentBlock>.size

        fileHandle.seek(toFileOffset: 0)

        while offset + UInt64(headerSize) < fileSize {
            fileHandle.seek(toFileOffset: offset)

            if let headerData = try fileHandle.read(upToCount: headerSize),
                headerData.count == headerSize {
                let header = headerData.withUnsafeBytes { bytes in
                    bytes.bindMemory(to: ContentBlock.self).baseAddress!.pointee
                }

                if header.magic == 0xC0FF_EE42 {
                    // Valid block, advance offset
                    let blockSize = headerSize + Int(header.dataSize)
                    let alignedSize = ((blockSize + 15) / 16) * 16
                    offset += UInt64(alignedSize)
                } else {
                    // Invalid block, this is our write position
                    break
                }
            } else {
                break
            }
        }

        return offset
    }

    private func growFile(to newSize: Int) throws {
        // Similar to MappedFile.growFile but for content storage
        let pageSize = 4096  // Use standard page size
        let alignedSize = ((newSize + pageSize - 1) / pageSize) * pageSize

        munmap(memoryMap, fileSize)
        try fileHandle.truncate(atOffset: UInt64(alignedSize))

        let fd = fileHandle.fileDescriptor
        let newMap = mmap(nil, alignedSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)

        guard newMap != MAP_FAILED else {
            throw MMapError.remapFailed(errno)
        }

        memoryMap = newMap!
        fileSize = alignedSize
        madvise(memoryMap, fileSize, MADV_SEQUENTIAL)
    }
}

// MARK: - Supporting Types

struct ContentBlock {
    let magic: UInt32  // 0xC0FFEE42
    let checksum: UInt32  // CRC32
    let encoding: ContentEncoding
    let reserved: UInt8 = 0
    let reserved2: UInt16 = 0
    let dataSize: UInt32
    // Data follows immediately after
}

enum ContentEncoding: UInt8 {
    case utf8 = 0
    case utf16 = 1
    case compressed = 2
}

struct ContentLocation {
    let offset: UInt64
    let length: UInt32
    let compressedLength: UInt32
}

struct StringLocation {
    let offset: UInt32
    let length: UInt32
}

// MARK: - Errors

enum MMapError: LocalizedError {
    case mappingFailed(Int32, String)
    case remapFailed(Int32)
    case syncFailed(Int32)
    case invalidOffset(Int)

    var errorDescription: String? {
        switch self {
        case let .mappingFailed(errno, message):
            return "Failed to map file: \(message) (errno: \(errno))"
        case .remapFailed(let errno):
            return "Failed to remap file: errno \(errno)"
        case .syncFailed(let errno):
            return "Failed to sync file: errno \(errno)"
        case .invalidOffset(let offset):
            return "Invalid file offset: \(offset)"
        }
    }
}

// MARK: - CRC32 Extension

extension Data {
    func crc32() -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF

        for byte in self {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 * (crc & 1))
            }
        }

        return ~crc
    }
}
