#!/bin/sh
# Xcode Cloud pre-build script - runs before build starts
set -e

echo "======================================"
echo "Xcode Cloud Pre-Build"
echo "======================================"

# Run code quality checks
echo "🔍 Running SwiftLint..."
swiftlint lint --strict --quiet || true

echo "📐 Checking code format..."
swift-format lint -r Shared macOS iOS Tests || true

# Update build number for archives
if [ -n "$CI_BUILD_NUMBER" ]; then
    echo "📝 Setting build number to $CI_BUILD_NUMBER"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CI_BUILD_NUMBER" macOS/Info.plist
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CI_BUILD_NUMBER" iOS/Info.plist
fi

# Set version based on tag if present
if [ -n "$CI_TAG" ]; then
    # Extract version from tag (assumes tags like v1.0.0)
    VERSION=$(echo $CI_TAG | sed 's/^v//')
    if [ -n "$VERSION" ]; then
        echo "📝 Setting version to $VERSION based on tag $CI_TAG"
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" macOS/Info.plist
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" iOS/Info.plist
    fi
fi

echo "✅ Pre-build complete"