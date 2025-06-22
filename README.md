# Prompt

A native SwiftUI application for macOS and iOS that helps you manage, organize, and analyze prompts with AI-powered features.

## Features

- 📝 **Prompt Management**: Create, edit, and organize prompts with categories and tags
- 🔍 **Smart Search**: Fast full-text search across all prompts
- 🤖 **AI Analysis**: Automatic categorization and tag suggestions (iOS 26/macOS 26)
- ☁️ **iCloud Sync**: Seamless sync across all your devices
- 🎯 **Platform Native**: Built with SwiftUI for macOS and iOS
- 🚀 **High Performance**: Optimized with Swift 6 concurrency

## Requirements

- macOS 26.0 (Tahoe) or later
- iOS 26.0 or later
- Xcode 16.0 or later
- Swift 6.0

## Development Setup

### Prerequisites

```bash
# Install Homebrew (if not already installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install required tools
brew install xcodegen swiftlint swift-format fswatch
```

### Quick Start

1. Clone the repository:
```bash
git clone <repository-url>
cd PromptBank
```

2. Run the setup:
```bash
make setup
```

3. Open the project:
```bash
make dev
```

## Development Workflow

### Available Make Commands

```bash
make help          # Show all available commands
make dev           # Start development (generate + test + open)
make tdd           # Start TDD watch mode
make build         # Build all platforms
make test          # Run all tests
make lint          # Run SwiftLint
make format        # Format code with swift-format
make clean         # Clean build artifacts
```

### Test-Driven Development

The project follows TDD principles. To start the TDD workflow:

```bash
make tdd
```

This will watch for file changes and automatically run tests.

### Running Tests

```bash
# Run all tests
make test

# Run unit tests only
make test-quick

# Run AI-specific tests
make test-ai
```

## Project Structure

```
PromptBank/
├── Shared/           # ~80% of codebase (cross-platform)
│   ├── Models/       # SwiftData models
│   ├── Services/     # Actor-based services
│   ├── Views/        # Universal SwiftUI views
│   ├── AIServices/   # AI integration
│   └── Utils/        # Extensions and helpers
├── macOS/            # macOS-specific code
├── iOS/              # iOS-specific code
├── Tests/            # Swift Testing framework tests
├── ci_scripts/       # Xcode Cloud CI/CD scripts
└── Makefile          # Build automation
```

## Architecture

- **MV Pattern**: Modern SwiftUI architecture without ViewModels
- **Actor-Based Services**: Thread-safe state management
- **SwiftData**: Local storage with CloudKit sync
- **Swift Testing**: New testing framework with @Test/@Suite
- **Foundation Models**: AI features (when available)

## CI/CD

The project uses Xcode Cloud for continuous integration:

- Automatic builds on push/PR
- Test execution with coverage
- Code quality checks (SwiftLint, swift-format)
- Release builds on tags

## Contributing

1. Fork the repository
2. Create a feature branch
3. Follow TDD: Write tests first
4. Ensure all tests pass
5. Run `make lint` and `make format`
6. Submit a pull request

## License

Copyright © 2024 Prompt. All rights reserved.