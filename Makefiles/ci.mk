# CI/CD specific makefile targets

.PHONY: ci-setup ci-test ci-lint ci-build ci-archive

# CI environment setup
ci-setup:
	@echo "🔧 Setting up CI environment..."
	@./ci_scripts/ci_post_clone.sh

# CI test runner
ci-test:
	@echo "🧪 Running tests in CI mode..."
	@xcodebuild test \
		-project Prompt.xcodeproj \
		-scheme Prompt-macOS \
		-testPlan AllTests \
		-configuration CI \
		-quiet

# CI linting
ci-lint:
	@echo "🔍 Running strict linting..."
	@swiftlint lint --strict --reporter json > lint-report.json || true

# CI build verification
ci-build:
	@echo "🏗️ Building for CI..."
	@xcodebuild build \
		-project Prompt.xcodeproj \
		-scheme Prompt-macOS \
		-configuration Debug \
		CODE_SIGN_IDENTITY="" \
		CODE_SIGNING_REQUIRED=NO

# CI archive for release
ci-archive:
	@echo "📦 Creating archive..."
	@xcodebuild archive \
		-project Prompt.xcodeproj \
		-scheme Prompt-macOS \
		-configuration Release \
		-archivePath ./build/Prompt.xcarchive