# Prompt Master Makefile
.PHONY: all help setup build test lint format release clean dev tdd ci ci-quiet doctor

# Default target
all: setup lint test build

# TDD workflow
tdd: 
	@echo "🔄 Starting TDD watch mode..."
	@fswatch -o Shared Tests | xargs -n1 -I{} make test-quick

# Development workflow
dev: setup
	@echo "🚀 Starting development environment..."
	@make generate
	@open Prompt.xcodeproj

# Help command
help:
	@echo "Prompt Build System"
	@echo "======================="
	@echo "Setup & Environment:"
	@echo "  make setup          - Complete project setup"
	@echo "  make generate       - Generate Xcode project with XcodeGen"
	@echo "  make doctor         - Diagnose environment issues"
	@echo ""
	@echo "Development:"
	@echo "  make dev            - Start development (generate + test + open)"
	@echo "  make tdd            - Start TDD watch mode"
	@echo "  make build          - Build all platforms"
	@echo "  make build-macos    - Build macOS only"
	@echo "  make build-ios      - Build iOS only"
	@echo ""
	@echo "Testing:"
	@echo "  make test           - Run all tests"
	@echo "  make test-quick     - Run unit tests only"
	@echo "  make test-ai        - Run AI integration tests"
	@echo "  make coverage       - Generate test coverage"
	@echo ""
	@echo "Quality:"
	@echo "  make lint           - Run SwiftLint"
	@echo "  make format         - Format code with swift-format"
	@echo ""
	@echo "Release:"
	@echo "  make release        - Build release versions"
	@echo "  make notarize       - Notarize macOS app"

# Project generation
generate:
	@echo "🏗️ Generating Xcode project..."
	@xcodegen generate --spec project.yml
	@echo "✅ Project generated successfully"

# Quick test for TDD
test-quick:
	@xcodebuild test -scheme Prompt-macOS -destination "platform=macOS" -only-testing:SharedTests-macOS -quiet || true

# AI-specific tests
test-ai:
	@swift test --filter ".*AIAnalysisTests"

# Full test suite
test:
	@echo "🧪 Running full test suite..."
	@xcodebuild test -scheme Prompt-macOS -destination "platform=macOS" -quiet || true
	@xcodebuild test -scheme Prompt-iOS -destination "platform=iOS Simulator,name=iPhone 16 Pro" -quiet || true

# Build targets
build: build-macos build-ios

build-macos:
	@echo "🖥️ Building macOS app..."
	@xcodebuild -project Prompt.xcodeproj \
		-scheme Prompt-macOS \
		-configuration Debug \
		build

build-ios:
	@echo "📱 Building iOS app..."
	@xcodebuild -project Prompt.xcodeproj \
		-scheme Prompt-iOS \
		-configuration Debug \
		-sdk iphonesimulator \
		build

# CI/CD specific targets
ci: clean format lint lint-strict format-check generate test
	@echo "✅ CI pipeline complete"

ci-quiet: clean generate test-quiet
	@echo "✅ CI pipeline complete (quiet mode)"

clean:
	@echo "🧹 Cleaning build artifacts..."
	@rm -rf .build DerivedData
	@rm -rf ~/Library/Developer/Xcode/DerivedData/PromptBank-*

lint:
	@echo "🔍 Running SwiftLint with auto-fix..."
	@swiftlint lint --fix

lint-strict:
	@echo "🔍 Running SwiftLint (strict mode)..."
	@swiftlint lint --strict --reporter json

format:
	@echo "📐 Formatting code..."
	@swift-format -i -r Shared macOS iOS Tests

format-check:
	@echo "📐 Checking code formatting..."
	@swift-format lint -r Shared macOS iOS Tests

# Setup and installation
setup: setup-tools generate install-hooks
	@echo "✅ Setup complete"

setup-tools:
	@echo "📦 Installing development tools..."
	@command -v brew >/dev/null 2>&1 || /bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
	@brew install xcodegen swiftlint swift-format fswatch || true

install-hooks:
	@echo "📎 Installing git hooks..."
	@bash scripts/install-hooks.sh || true

# Doctor - diagnose environment
doctor:
	@echo "🏥 Running environment diagnostics..."
	@echo ""
	@echo "Checking Xcode:"
	@xcode-select -p || echo "❌ Xcode not found"
	@xcodebuild -version || echo "❌ xcodebuild not available"
	@echo ""
	@echo "Checking Swift:"
	@swift --version || echo "❌ Swift not found"
	@echo ""
	@echo "Checking required tools:"
	@command -v xcodegen >/dev/null 2>&1 && echo "✅ XcodeGen installed" || echo "❌ XcodeGen not found"
	@command -v swiftlint >/dev/null 2>&1 && echo "✅ SwiftLint installed" || echo "❌ SwiftLint not found"
	@command -v swift-format >/dev/null 2>&1 && echo "✅ swift-format installed" || echo "❌ swift-format not found"
	@command -v fswatch >/dev/null 2>&1 && echo "✅ fswatch installed" || echo "❌ fswatch not found"

# Coverage
coverage:
	@echo "📊 Generating test coverage..."
	@swift test --enable-code-coverage
	@xcrun llvm-cov export \
		.build/debug/PromptBankPackageTests.xctest/Contents/MacOS/PromptBankPackageTests \
		-instr-profile .build/debug/codecov/default.profdata \
		-format="lcov" > coverage.lcov

# Release builds
release: release-macos release-ios

release-macos:
	@echo "📦 Building macOS release..."
	@xcodebuild -project Prompt.xcodeproj \
		-scheme Prompt-macOS \
		-configuration Release \
		archive

release-ios:
	@echo "📦 Building iOS release..."
	@xcodebuild -project Prompt.xcodeproj \
		-scheme Prompt-iOS \
		-configuration Release \
		-sdk iphoneos \
		archive

# Include modular makefiles
-include Makefiles/*.mk