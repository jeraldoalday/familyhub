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

# Optimisations surface warnings a debug build hides, and this is the
# configuration the App Store actually receives.
.PHONY: release
release: ## Build with optimisations, as the app target will
	swift build -c release

# Deliberately the same set of checks CI runs, in the order that fails fastest.
# The release build is the slow one — about ten seconds on a warm cache — and it
# is here rather than in a separate target nobody remembers to run, because a
# gate that agrees with CI except in one place is a gate people learn to skip
# and then a red X on a pull request that says nothing about the code.
.PHONY: check
check: build test lint release ## Build, test, lint, and release-build — the pre-commit gate

.PHONY: clean
clean: ## Remove build artefacts
	rm -rf .build

# The exact command CI runs. Anything else here — a differently configured
# linter, a laxer flag set — means a branch can pass locally and fail on push,
# which teaches people to stop trusting the local gate.
SWIFT_FORMAT := swift format

.PHONY: lint
lint: ## Check formatting, exactly as CI does
	$(SWIFT_FORMAT) lint --recursive --strict Sources Tests

.PHONY: format
format: ## Reformat sources in place
	$(SWIFT_FORMAT) format --in-place --recursive Sources Tests

.PHONY: help
help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
