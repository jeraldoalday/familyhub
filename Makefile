# FamilyHub — developer tasks
#
# The domain and store layers build with the Command Line Tools alone. Swift
# Testing, however, ships as a framework outside the default search path when
# Xcode is not installed, so `swift test` cannot find it without help. These
# variables supply that help; on a machine with full Xcode they resolve to
# nothing useful but do no harm, and CI runs plain `swift test`.

CLT_DEVELOPER := /Library/Developer/CommandLineTools/Library/Developer
TESTING_FRAMEWORKS := $(CLT_DEVELOPER)/Frameworks
TESTING_LIBS := $(CLT_DEVELOPER)/usr/lib

# Only inject the flags when Xcode is absent, so developers with the full
# toolchain get the stock, unmodified build.
ifeq ($(wildcard /Applications/Xcode.app),)
TEST_FLAGS := \
	-Xswiftc -F -Xswiftc $(TESTING_FRAMEWORKS) \
	-Xlinker -F -Xlinker $(TESTING_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(TESTING_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(TESTING_LIBS)
else
TEST_FLAGS :=
endif

.DEFAULT_GOAL := check

.PHONY: build
build: ## Build the domain and store layers
	swift build

.PHONY: test
test: ## Run the full test suite
	swift test $(TEST_FLAGS)

.PHONY: release
release: ## Build with optimisations, as the app target will
	swift build -c release

.PHONY: check
check: build test ## Build and test — the pre-commit gate

.PHONY: clean
clean: ## Remove build artefacts
	rm -rf .build

.PHONY: lint
lint: ## Run SwiftLint if it is installed
	@command -v swiftlint >/dev/null 2>&1 \
		&& swiftlint lint --quiet \
		|| echo "swiftlint not installed — skipping (brew install swiftlint)"

.PHONY: format
format: ## Format sources with swift-format if it is installed
	@command -v swift-format >/dev/null 2>&1 \
		&& swift-format format --in-place --recursive Sources Tests \
		|| echo "swift-format not installed — skipping"

.PHONY: help
help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
