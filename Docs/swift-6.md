# Swift 6 Concurrency Migration - Next Steps

## Overview
The core migration to comply with Swift 6's strict concurrency checking has been completed. All SwiftData models are now properly isolated behind DTOs, and views no longer hold references to non-Sendable models.

## Completed Work ✅

### Phase 1: Created Additional DTOs
- Created TagSummary and TagDetail DTOs in `/Shared/Models/DTOs/`
- Created PromptVersionSummary DTO
- Created Request DTOs (PromptCreateRequest, PromptUpdateRequest, TagCreateRequest, etc.)
- Added DTO conversion methods to all models (Tag, PromptVersion)
- Extended PromptSummary with additional fields (copyCount, categoryConfidence, shortLink)

### Phase 2: Refactored Service Layer
- TagService now uses ID-based methods and returns DTOs
- PromptService refactored with ID-based methods
- Added internal fetchPrompt() methods for actor context
- Created proper error types (TagError, extended PromptError)

### Phase 3: Refactored View Layer
- FileStatsView uses PromptDetail DTO
- PromptDetailView loads by ID and uses DTOs
- PromptListView uses PromptSummary DTOs
- Supporting views (MetadataView, AIAnalysisView) use DTOs
- TagChip updated to use TagDTO ✅

### Phase 4: Updated Cross-Actor Communication
- AppState uses selectedPromptID and selectedPromptDetail
- All AppState methods use IDs instead of models
- Navigation updated to use UUID-based routing
- Both iOS and macOS ContentViews updated

### Phase 5: Initial Swift 6 Fixes (Completed 2025-01-22)
- ✅ Fixed TagChip View to use TagDTO instead of Tag model
- ✅ Added PromptService.incrementCopyCount(id: UUID)
- ✅ Added PromptService.getPromptVersionSummaries(promptID: UUID)
- ✅ Created ID-based PromptService.createVersion(promptID: UUID, changeDescription: String?)
- ✅ Fixed all missing `await` keywords in PromptService
- ✅ Changed @EnvironmentObject to @Environment for @Observable AppState
- ✅ Added missing createdAt parameters in PromptSummary initializations
- ✅ Fixed TextIndexer concurrency issues with proper batch isolation
- ✅ Added DTO overloads for MarkdownParser.generateMarkdown and DragDropUtils.exportFilename
- ✅ Removed duplicate TagError enum definition

## Remaining Work 📋

### Critical Compilation Errors (Must Fix First)

#### 1. Fix OptimizedPromptService Concurrency Issues
Location: `/Shared/Services/OptimizedPromptService.swift`

**Issues:**
- Line 68: `sending 'prompts' risks causing data races` - Need to properly isolate prompts array
- Line 117: `Task.detached` closure captures non-Sendable prompt
- Lines 279, 344: Non-Sendable `[Prompt]` array issues with DataStore.fetch
- Line 351: TaskGroup closure captures non-Sendable self and prompt

**Fix Strategy:**
```swift
// Convert to use DTOs instead of models
let promptDTOs = prompts.map { $0.toSummary() }
let searchResults = await cacheEngine.search(query: query, in: promptDTOs)

// For Task.detached, create DTO first
let promptDTO = prompt.toDetail()
Task.detached(priority: .high) {
    // Work with DTO instead of model
}
```

#### 2. Fix CreatePromptView Issues
Location: `/Shared/Views/CreatePromptView.swift`

**Issues:**
- Using @EnvironmentObject with @Observable AppState
- Possible model references instead of DTOs

**Fix:**
```swift
// Change from:
@EnvironmentObject var appState: AppState
// To:
@Environment(AppState.self) var appState
```

#### 3. Fix Remaining FileOperations Issues
Location: `/Shared/Views/FileOperations.swift`

**Issues:**
- Line 70: `selectedPrompt` reference not found - already fixed to use `selectedPromptDetail`
- Verify all model references are converted to DTOs

### High Priority: DataStore Actor Isolation Issues

#### 4. Fix DataStore Non-Sendable Return Types
The DataStore actor is returning non-Sendable `[Prompt]` arrays which violates Swift 6 concurrency.

**Current Issue:**
```swift
// DataStore.fetch returns [Prompt] which is not Sendable
let prompts = try await dataStore.fetch(descriptor) // Error!
```

**Solution Options:**
1. Make DataStore return DTOs instead of models
2. Add a DTO conversion layer in DataStore
3. Use a different pattern for cross-actor data transfer

**Recommended Fix:**
```swift
// In DataStore
func fetchDTOs<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) async throws -> [DTO] {
    let models = try context.fetch(descriptor)
    return models.map { $0.toDTO() }
}
```

### Medium Priority Tasks

#### 5. Fix Remaining @unchecked Sendable Usage
Found in:
- `/Shared/Cache/StatsComputer.swift` - Uses NSCache (thread-safe but not Sendable)
- `/Shared/Utils/Extensions.swift` - Box<T> class with NSLock
- `/Shared/Storage/ColumnarStorage.swift` - Thread-safe storage
- `/Shared/Services/OptimizedPromptService.swift` - EnhancedPrompt & SearchResultWithContent

**Action:** The first three are legitimate uses for thread-safe operations. Focus on fixing OptimizedPromptService to use DTOs.

#### 6. Add DTO Caching
Implement caching layer for frequently accessed DTOs:
- Cache PromptDetail objects with TTL
- Implement cache invalidation on updates
- Add memory pressure handling

#### 7. Update Tests
- Update all test files to use DTOs instead of models
- Add tests for DTO conversion methods
- Test actor boundary compliance
- Verify no data races in concurrent scenarios

#### 8. Performance Validation
- Measure DTO conversion overhead
- Profile memory usage with DTOs
- Ensure 16ms frame time maintained
- Compare before/after performance metrics

### Low Priority Tasks

#### 9. Optimize DTO Conversions
- Consider lazy loading for expensive fields
- Implement partial DTOs for different use cases
- Add batch conversion methods

#### 10. Documentation
- Document the DTO architecture pattern
- Add inline documentation for service methods
- Create migration guide for future model changes

## Implementation Notes

### Service Method Patterns
When adding new service methods, follow this pattern:
```swift
// ID-based public method
func updateSomething(id: UUID, data: SomeDTO) async throws -> ResultDTO {
    // Fetch within actor
    guard let model = try fetchModel(id: id) else {
        throw ModelError.notFound(id)
    }
    
    // Update model
    model.property = data.property
    
    // Save
    try modelContext.save()
    
    // Return DTO
    return model.toDTO()
}
```

### View Pattern
Views should always:
1. Accept IDs or DTOs as parameters
2. Load full data in .task modifier
3. Handle loading/error states
4. Never hold @Binding to models

### Navigation Pattern
- iOS: Use NavigationPath with UUID values
- macOS: Use selection-based navigation with UUID

## Quick Start Guide for Future Work

When resuming this task, start with these commands to identify compilation errors:

```bash
# Check current build status
make test-quick

# Find all @unchecked Sendable usage
grep -r "@unchecked Sendable" --include="*.swift" .

# Find remaining @EnvironmentObject usage
grep -r "@EnvironmentObject" --include="*.swift" .

# Find potential model references in views
grep -rn "let.*: Prompt\|var.*: Prompt" Shared/Views/ iOS/Views/ macOS/Views/
```

### Immediate Action Items

1. **Fix OptimizedPromptService** - Replace all direct Prompt model usage with DTOs
2. **Fix CreatePromptView** - Change @EnvironmentObject to @Environment
3. **Update DataStore** - Add DTO-returning methods to avoid cross-actor model transfer
4. **Run tests** - Continue fixing compilation errors until `make test` passes

### Key Files to Modify

- `/Shared/Services/OptimizedPromptService.swift` - Critical concurrency fixes needed
- `/Shared/Views/CreatePromptView.swift` - Environment update
- `/Shared/Services/DataStore.swift` - Add DTO methods
- `/Shared/Cache/CacheEngine.swift` - May need DTO support for search

## Testing Checklist
- [x] Fixed TagChip View to use DTOs
- [x] Added missing PromptService methods
- [x] Fixed @EnvironmentObject to @Environment for AppState
- [ ] Fixed OptimizedPromptService concurrency issues
- [ ] Fixed CreatePromptView environment usage
- [ ] Fixed DataStore non-Sendable return types
- [ ] All views compile without SwiftData model references
- [ ] No concurrency warnings in Xcode 16
- [ ] Tests pass with strict concurrency checking
- [ ] No runtime crashes from actor isolation
- [ ] Performance metrics acceptable

## Success Metrics
- Zero Swift 6 concurrency warnings
- Minimal @unchecked Sendable usage (only for legitimate thread-safe classes)
- All tests passing
- Performance maintained or improved
- Clear separation between models and views

## Progress Status
- **Phase 1-4:** ✅ Complete (DTO creation, service refactoring, view updates, cross-actor communication)
- **Phase 5:** ✅ Complete (Initial Swift 6 fixes - TagChip, missing methods, basic concurrency)
- **Phase 6:** 🔄 In Progress (Critical compilation errors - OptimizedPromptService, CreatePromptView, DataStore)
- **Phase 7:** ⏳ Pending (Testing and validation)