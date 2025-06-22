#!/bin/bash

echo "🔍 Validating Prompt Bank Project Setup"
echo "======================================"

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Validation results
ERRORS=0
WARNINGS=0

# Function to check if a file exists
check_file() {
    if [ -f "$1" ]; then
        echo -e "${GREEN}✓${NC} $2"
    else
        echo -e "${RED}✗${NC} $2 - Missing: $1"
        ((ERRORS++))
    fi
}

# Function to check if a directory exists
check_dir() {
    if [ -d "$1" ]; then
        echo -e "${GREEN}✓${NC} $2"
    else
        echo -e "${RED}✗${NC} $2 - Missing: $1"
        ((ERRORS++))
    fi
}

# Function to check if a command exists
check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $2 installed"
    else
        echo -e "${YELLOW}⚠${NC} $2 not installed - Install with: brew install $1"
        ((WARNINGS++))
    fi
}

echo ""
echo "1. Checking project structure..."
echo "--------------------------------"
check_dir "Shared" "Shared code directory"
check_dir "macOS" "macOS platform directory"
check_dir "iOS" "iOS platform directory"
check_dir "Tests" "Tests directory"
check_dir "ci_scripts" "CI scripts directory"
check_dir "Makefiles" "Makefiles directory"

echo ""
echo "2. Checking essential files..."
echo "------------------------------"
check_file "Makefile" "Master Makefile"
check_file "project.yml" "XcodeGen configuration"
check_file "README.md" "Project documentation"
check_file ".swiftlint.yml" "SwiftLint configuration"
check_file ".swift-format" "Swift format configuration"

echo ""
echo "3. Checking platform files..."
echo "-----------------------------"
check_file "macOS/App.swift" "macOS app entry point"
check_file "iOS/App.swift" "iOS app entry point"
check_file "macOS/Info.plist" "macOS Info.plist"
check_file "iOS/Info.plist" "iOS Info.plist"
check_file "macOS/PromptBank.entitlements" "macOS entitlements"
check_file "iOS/PromptBank.entitlements" "iOS entitlements"

echo ""
echo "4. Checking CI/CD scripts..."
echo "----------------------------"
check_file "ci_scripts/ci_post_clone.sh" "Post-clone script"
check_file "ci_scripts/ci_pre_xcodebuild.sh" "Pre-build script"
check_file "ci_scripts/ci_post_xcodebuild.sh" "Post-build script"

# Check if scripts are executable
if [ -f "ci_scripts/ci_post_clone.sh" ] && [ -x "ci_scripts/ci_post_clone.sh" ]; then
    echo -e "${GREEN}✓${NC} CI scripts are executable"
else
    echo -e "${YELLOW}⚠${NC} CI scripts need executable permissions"
    ((WARNINGS++))
fi

echo ""
echo "5. Checking development tools..."
echo "--------------------------------"
check_command "xcodegen" "XcodeGen"
check_command "swiftlint" "SwiftLint"
check_command "swift-format" "swift-format"
check_command "fswatch" "fswatch"

echo ""
echo "6. Checking Swift files..."
echo "--------------------------"
SWIFT_COUNT=$(find Shared macOS iOS Tests -name "*.swift" 2>/dev/null | wc -l | tr -d ' ')
if [ "$SWIFT_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓${NC} Found $SWIFT_COUNT Swift files"
else
    echo -e "${RED}✗${NC} No Swift files found"
    ((ERRORS++))
fi

echo ""
echo "7. Checking test files..."
echo "-------------------------"
TEST_COUNT=$(find Tests -name "*Tests.swift" 2>/dev/null | wc -l | tr -d ' ')
if [ "$TEST_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓${NC} Found $TEST_COUNT test files"
else
    echo -e "${YELLOW}⚠${NC} No test files found"
    ((WARNINGS++))
fi

echo ""
echo "======================================"
echo "Validation Summary"
echo "======================================"

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✅ All checks passed!${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Run 'make setup' to install dependencies"
    echo "2. Run 'make dev' to start development"
    echo "3. Run 'make help' to see all available commands"
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}⚠️  Validation completed with $WARNINGS warnings${NC}"
    echo ""
    echo "The project is functional but some optional tools are missing."
    echo "Consider installing the missing tools for the best experience."
    exit 0
else
    echo -e "${RED}❌ Validation failed with $ERRORS errors and $WARNINGS warnings${NC}"
    echo ""
    echo "Please fix the errors before proceeding."
    exit 1
fi