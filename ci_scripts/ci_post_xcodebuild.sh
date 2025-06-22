#!/bin/sh
# Xcode Cloud post-build script - runs after build completes
set -e

echo "======================================"
echo "Xcode Cloud Post-Build"
echo "======================================"

# Report test results
if [ "$CI_XCODEBUILD_ACTION" = "test" ]; then
    echo "📊 Test Summary:"
    echo "Total tests: $CI_TEST_COUNT"
    echo "Passed: $CI_TEST_PASSED_COUNT"
    echo "Failed: $CI_TEST_FAILED_COUNT"
    echo "Skipped: $CI_TEST_SKIPPED_COUNT"
    
    # Create test summary file for artifacts
    cat > test_summary.txt << EOF
Test Results Summary
===================
Build Number: $CI_BUILD_NUMBER
Date: $(date)

Total Tests: $CI_TEST_COUNT
Passed: $CI_TEST_PASSED_COUNT
Failed: $CI_TEST_FAILED_COUNT
Skipped: $CI_TEST_SKIPPED_COUNT
Success Rate: $(awk "BEGIN {printf \"%.1f\", ($CI_TEST_PASSED_COUNT/$CI_TEST_COUNT)*100}")%
EOF
fi

# Report archive details
if [ "$CI_XCODEBUILD_ACTION" = "archive" ]; then
    echo "📦 Archive created successfully"
    echo "Build Number: $CI_BUILD_NUMBER"
    echo "Product: $CI_PRODUCT"
    
    # Create build info file for artifacts
    cat > build_info.txt << EOF
Build Information
================
Build Number: $CI_BUILD_NUMBER
Product: $CI_PRODUCT
Branch: $CI_BRANCH
Tag: $CI_TAG
Date: $(date)
EOF
fi

# Generate release notes if this is a tagged build
if [ -n "$CI_TAG" ]; then
    echo "📝 Generating release notes..."
    cat > release_notes.md << EOF
# Prompt Bank Release Notes

Version: $CI_TAG
Build: $CI_BUILD_NUMBER
Date: $(date)

## What's New

- Enhanced prompt management capabilities
- Improved AI analysis features
- Performance optimizations
- Bug fixes and stability improvements

## Requirements

- macOS 26.0 or later
- iOS 26.0 or later

---
🤖 Built with Xcode Cloud
EOF
fi

echo "✅ Post-build complete"