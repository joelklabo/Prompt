# Hybrid Storage Implementation Plan

## Overview

This plan migrates your SwiftData-based app from storing large markdown content directly in models to a hybrid approach that keeps metadata in SwiftData while storing content externally. This will dramatically improve performance while maintaining your existing architecture.

**Expected Outcomes:**
- 80% memory reduction
- <16ms list view loading (from ~100ms+)
- <50ms search performance
- Maintained CloudKit sync functionality
- Zero data loss during migration

## Prerequisites

Before starting, ensure you have:
- [ ] Full backup of production data
- [ ] Test dataset with >1000 prompts including large (>100KB) documents
- [ ] Performance baseline metrics documented
- [ ] Unit tests passing

## Phase 1: Foundation (Days 1-2)

### Task 1.1: Add Content Metadata Fields to Models
**Time: 2 hours**

1. Update `Shared/Models/Prompt.swift`:
```swift
@Model
final class Prompt {
    // Existing fields...
    
    // New fields for hybrid storage
    var contentHash: String?
    var contentSize: Int
    var contentPreview: String
    var storageType: StorageType
    
    // Transient cache (not persisted)
    @Transient var _cachedContent: String?
    
    enum StorageType: String, Codable {
        case swiftData = "swiftdata"  // Legacy
        case external = "external"    // New hybrid storage
    }
}
```

2. Create migration to populate new fields for existing data
3. Test that existing functionality still works

**Deliverable:** Models updated with new fields, all tests passing

### Task 1.2: Create External Content Store
**Time: 4 hours**

1. Create `Shared/Storage/HybridContentStore.swift`:
```swift
actor HybridContentStore {
    private let sqliteDB: SQLiteContentDB
    private let fileStore: ContentAddressableStore
    
    // Threshold for SQLite vs file storage
    private let sqliteThreshold = 100 * 1024 // 100KB
    
    func store(_ content: String) async throws -> ContentReference
    func retrieve(_ reference: ContentReference) async throws -> String
    func delete(_ reference: ContentReference) async throws
}
```

2. Implement SQLite backend for content <100KB
3. Use existing ContentAddressableStore for larger content
4. Add compression for text content

**Deliverable:** Working content store with tests

### Task 1.3: Create Content Migration Service
**Time: 3 hours**

1. Create `Shared/Services/ContentMigrationService.swift`:
```swift
actor ContentMigrationService {
    func migratePromptContent(_ prompt: Prompt) async throws
    func migrateAllContent(batchSize: Int = 100) async throws
    func verifyMigration() async throws -> MigrationReport
}
```

2. Implement batch processing with progress reporting
3. Add verification to ensure content integrity
4. Create rollback mechanism

**Deliverable:** Migration service that can safely move content

## Phase 2: Service Layer Updates (Days 3-4)

### Task 2.1: Update PromptService for Lazy Loading
**Time: 3 hours**

1. Modify `PromptService.swift`:
```swift
// Add content loading methods
func loadContent(for prompt: Prompt) async throws -> String
func loadContentIfNeeded(for prompt: Prompt) async throws

// Update create/update to use hybrid storage
func createPrompt(title: String, content: String, category: Category) async throws -> Prompt {
    // Store content externally
    let reference = try await contentStore.store(content)
    
    // Create prompt with metadata only
    let prompt = Prompt(
        title: title,
        contentHash: reference.hash,
        contentSize: content.utf8.count,
        contentPreview: String(content.prefix(200)),
        storageType: .external,
        category: category
    )
    
    modelContext.insert(prompt)
    try modelContext.save()
    return prompt
}
```

2. Update all methods that access content
3. Ensure backward compatibility with legacy storage

**Deliverable:** PromptService supporting both storage types

### Task 2.2: Optimize List Queries
**Time: 3 hours**

1. Update `fetchPromptSummaries` to exclude content:
```swift
func fetchPromptSummaries() async throws -> [PromptSummary] {
    var descriptor = FetchDescriptor<Prompt>()
    descriptor.propertiesToFetch = [
        \Prompt.id,
        \Prompt.title,
        \Prompt.contentPreview,
        \Prompt.category,
        \Prompt.createdAt
    ]
    
    let prompts = try modelContext.fetch(descriptor)
    return prompts.map { /* convert to summary */ }
}
```

2. Add prefetching for adjacent content
3. Update search to use contentPreview first

**Deliverable:** List views loading in <20ms

### Task 2.3: Update Caching Strategy
**Time: 2 hours**

1. Modify cache to store content separately:
```swift
actor PromptCache {
    private var metadataCache: LRUCache<UUID, PromptSummary>
    private var contentCache: LRUCache<UUID, String>
    
    func cacheContent(_ content: String, for id: UUID)
    func getCachedContent(for id: UUID) -> String?
}
```

2. Implement smart eviction based on access patterns
3. Add memory pressure handling

**Deliverable:** Two-tier cache system

## Phase 3: UI Updates (Days 5-6)

### Task 3.1: Update List Views
**Time: 2 hours**

1. Modify `PromptListView.swift`:
- Use contentPreview for list display
- Remove full content loading from list
- Add loading states for content

2. Update `PromptRow` to show preview only
3. Add visual indicator for content loading state

**Deliverable:** Fast-loading list views

### Task 3.2: Update Detail View
**Time: 3 hours**

1. Modify `PromptDetailView.swift`:
```swift
struct PromptDetailView: View {
    @State private var content: String?
    @State private var isLoadingContent = false
    
    var body: some View {
        Group {
            if let content = content {
                MarkdownView(content: content)
            } else if isLoadingContent {
                ProgressView("Loading content...")
            } else {
                ContentPreviewView(preview: prompt.contentPreview)
            }
        }
        .task {
            await loadContent()
        }
    }
}
```

2. Add progressive loading for large documents
3. Implement error handling for failed loads

**Deliverable:** Detail view with lazy content loading

### Task 3.3: Update Search Interface
**Time: 2 hours**

1. Modify search to work with previews first
2. Add option to search full content (slower)
3. Update search results to show snippets

**Deliverable:** Functional search with performance options

## Phase 4: Migration & Testing (Days 7-8)

### Task 4.1: Run Migration in Development
**Time: 3 hours**

1. Create migration command:
```swift
func runMigration() async {
    let service = ContentMigrationService()
    
    // Migrate in batches
    try await service.migrateAllContent(batchSize: 100)
    
    // Verify
    let report = try await service.verifyMigration()
    print("Migration complete: \(report)")
}
```

2. Test with sample data
3. Monitor performance metrics
4. Verify CloudKit sync still works

**Deliverable:** Successful test migration

### Task 4.2: Performance Testing
**Time: 2 hours**

1. Measure key metrics:
- List view load time
- Search performance
- Memory usage
- Detail view load time

2. Compare with baseline
3. Identify any regressions

**Deliverable:** Performance report

### Task 4.3: Production Migration Plan
**Time: 2 hours**

1. Create backup strategy
2. Plan staged rollout:
   - Migrate 10 prompts, verify
   - Migrate 100 prompts, verify
   - Migrate remaining in batches
3. Create monitoring dashboard
4. Document rollback procedure

**Deliverable:** Production migration checklist

## Phase 5: CloudKit Integration (Days 9-10)

### Task 5.1: Update CloudKit Schema
**Time: 3 hours**

1. Add fields to CloudKit:
- contentHash
- contentSize
- storageType

2. Create CloudKit record for external content
3. Test sync with new fields

**Deliverable:** Updated CloudKit schema

### Task 5.2: Implement CloudKit Document Storage
**Time: 4 hours**

1. For content >1MB, use CKAsset:
```swift
func uploadLargeContent(_ content: String, for prompt: Prompt) async throws {
    let asset = CKAsset(fileURL: tempFile)
    let record = CKRecord(recordType: "PromptContent")
    record["promptId"] = prompt.id.uuidString
    record["content"] = asset
    
    try await container.save(record)
}
```

2. Handle sync conflicts
3. Implement progressive download

**Deliverable:** Large content CloudKit sync

## Verification Checklist

After each phase, verify:
- [ ] All unit tests pass
- [ ] No data loss
- [ ] Performance metrics improved
- [ ] CloudKit sync functional
- [ ] UI remains responsive
- [ ] Memory usage reduced

## Monitoring & Success Metrics

Track these KPIs:
1. **List Load Time**: Target <16ms (from ~100ms)
2. **Memory Usage**: Target 80% reduction
3. **Search Speed**: Target <50ms for 10K prompts
4. **User-Perceived Performance**: No loading spinners in lists

## Risk Mitigation

1. **Data Loss**: Full backup before each phase
2. **Performance Regression**: A/B test with feature flags
3. **CloudKit Issues**: Implement offline fallback
4. **Large Migration**: Use background processing

## Next Steps After Implementation

1. Monitor production metrics for 1 week
2. Gather user feedback
3. Consider Phase 6: SQL FTS for advanced search
4. Evaluate further optimizations

## Code Review Checklist

Before considering implementation complete:
- [ ] All TODOs addressed
- [ ] Error handling comprehensive
- [ ] Memory leaks checked
- [ ] Thread safety verified
- [ ] Documentation updated
- [ ] Performance baselines met

This plan provides a clear path forward with minimal risk and maximum benefit. Each task is designed to be completed independently while building toward the complete solution.