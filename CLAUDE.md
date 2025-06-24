# Prompt App - Project Context for Claude

## Overview
Prompt is a SwiftUI/SwiftData application for macOS and iOS that helps users manage, organize, and analyze their prompts using AI.

## Architecture

### Key Technologies
- **SwiftUI** - UI framework
- **SwiftData** - Data persistence 
- **Swift 6** - Language version with strict concurrency
- **Hybrid Storage** - Combination of SwiftData and memory-mapped files for performance

### Project Structure
```
Prompt/
├── Shared/           # Code shared between macOS and iOS
│   ├── Models/       # SwiftData models (Prompt, Tag, AIAnalysis, etc.)
│   ├── Services/     # Business logic (PromptService, TagService, AIService)
│   ├── Views/        # Shared UI components
│   ├── ViewModels/   # AppState and view models
│   ├── Storage/      # Hybrid storage implementation
│   ├── Cache/        # Caching layer
│   └── Utils/        # Extensions and utilities
├── macOS/            # macOS-specific code
│   ├── App.swift     # Main app entry point
│   └── Views/        # macOS-specific views
├── iOS/              # iOS-specific code
│   └── Views/        # iOS-specific views
└── Tests/            # Unit and performance tests
```

## Recent Issues and Fixes

### 1. Tap Gesture Not Working on macOS
- **Issue**: Clicking on prompts in the list view didn't select them
- **Fix**: Added `.onTapGesture` handler for macOS in PromptListView.swift

### 2. App Crash on Launch
- **Issue**: ModelContainer initialization failed with assertion error
- **Fix**: Added proper entitlements in macOS/Prompt.entitlements:
  - `com.apple.security.app-sandbox`
  - `com.apple.security.files.user-selected.read-write`
  - `com.apple.security.network.client`

## Building and Running

### macOS
```bash
xcodebuild -project Prompt.xcodeproj -scheme Prompt-macOS -configuration Debug build
open build/Build/Products/Debug/Prompt-macOS.app
```

### iOS
```bash
xcodebuild -project Prompt.xcodeproj -scheme Prompt-iOS -configuration Debug -sdk iphonesimulator build
```

## Key Features
- Prompt management with categories and tags
- AI-powered analysis and categorization
- Version history tracking
- iCloud sync support
- Hybrid storage for performance
- Search and filtering capabilities
- Export functionality

## Testing
Run tests with:
```bash
xcodebuild test -project Prompt.xcodeproj -scheme Prompt-macOS
```

## Important Notes
- The app uses Swift 6 with strict concurrency checking
- SwiftData models require proper relationships and inverse relationships
- Entitlements are crucial for SwiftData to work properly
- The hybrid storage system is being implemented for better performance with large datasets

## Common Commands
- `swiftlint` - Run linting (if configured)
- `xcodebuild clean` - Clean build artifacts
- `git status` - Check changes
- `git diff` - View changes in detail