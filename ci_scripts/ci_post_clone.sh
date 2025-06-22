#!/bin/sh
# Xcode Cloud post-clone script - runs after repository is cloned
set -e

echo "======================================"
echo "Xcode Cloud Post-Clone Setup"
echo "======================================"

# Configure Homebrew for CI environment
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_EMOJI=1
export HOMEBREW_NO_ENV_HINTS=1

# Install build dependencies
echo "📦 Installing build dependencies..."
brew install xcodegen swiftlint swift-format || true

# Trust Swift Package plugins (required for SwiftLint integration)
echo "🔐 Configuring Swift Package plugin trust..."
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

# Generate Xcode project from specification
echo "🏗️ Generating Xcode project with XcodeGen..."
xcodegen generate --spec project.yml

# Verify project generation succeeded
if [ ! -f "PromptBank.xcodeproj/project.pbxproj" ]; then
    echo "❌ Failed to generate Xcode project"
    exit 1
fi

echo "✅ Post-clone setup complete"