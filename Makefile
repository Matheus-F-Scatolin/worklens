# Worklens — SwiftPM only, no Xcode project.
.PHONY: bootstrap setup build bundle icon sign dev-cert install run update dev test \
        format format-check lint-strings lint-design test-scripts check doctor-toolchain clean \
        install-env help

SHELL := /bin/bash
APP := build/Worklens.app
# The Command Line Tools toolchain ships Swift Testing under $(DEVELOPER_DIR)/Library/Developer
# but does not put it on a package's search paths the way Xcode.app does. Without these flags
# SwiftPM compiles the test bundle *without* the swift-testing entry point and `swift test`
# exits 0 having run nothing. Only added when the directory actually exists, so this is a
# no-op on a machine with a full Xcode.
DEVELOPER_DIR ?= $(shell xcode-select -p)
TESTING_FW := $(DEVELOPER_DIR)/Library/Developer/Frameworks
TESTING_LIB := $(DEVELOPER_DIR)/Library/Developer/usr/lib
SWIFT_TEST_FLAGS := $(if $(wildcard $(TESTING_FW)/Testing.framework),\
  -Xswiftc -F -Xswiftc "$(TESTING_FW)" \
  -Xlinker -rpath -Xlinker "$(TESTING_FW)" \
  -Xlinker -rpath -Xlinker "$(TESTING_LIB)",)
# …and since the 2026-09 Command Line Tools, `libTestingMacros.dylib` sits in a `testing/`
# subdirectory that the compiler's default plugin search does not descend into, so every `@Test`
# and `@Suite` fails to expand without this. Added alongside, not instead of, the default path.
TESTING_PLUGIN := $(DEVELOPER_DIR)/usr/lib/swift/host/plugins/testing
SWIFT_TEST_FLAGS += $(if $(wildcard $(TESTING_PLUGIN)/libTestingMacros.dylib),\
  -Xswiftc -plugin-path -Xswiftc "$(TESTING_PLUGIN)",)

# A Command Line Tools update can leave a macOS SDK newer than the Swift beside it, and that
# pair does not compile the SwiftUI target at all (see scripts/sdkroot.sh). When that is the
# case the script names an older SDK still on disk; normally it prints nothing and this is a
# no-op. An SDKROOT already in the environment always wins.
ifeq ($(origin SDKROOT),undefined)
MATCHED_SDKROOT := $(shell scripts/sdkroot.sh)
ifneq ($(MATCHED_SDKROOT),)
export SDKROOT := $(MATCHED_SDKROOT)
endif
endif

# Bare `make` lists the targets. Spelled out rather than left to "the first rule wins", which
# `setup` below would otherwise become — and a `make` typo that starts installing an app is not
# the kind of surprise this file should hold.
.DEFAULT_GOAL := help

help:  ## List targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

bootstrap:  ## What the one-line install runs: clone into ~/Library/Application Support/Worklens/src, then setup (BOOTSTRAP_ARGS=--dry-run prints the plan)
	scripts/bootstrap.sh $(BOOTSTRAP_ARGS)

setup:  ## First run on a new Mac: check the toolchain, build, sign, install, and say what is next
	scripts/setup.sh $(SETUP_ARGS)

build: doctor-toolchain  ## Release build of the Worklens binary
	swift build -c release

dev:  ## Debug build
	swift build

bundle:  ## Assemble build/Worklens.app from the release binary
	scripts/bundle.sh

icon:  ## Re-render AppIcon.icns, the glyph previews and docs/media/social-preview.png (ARGS=--banner: the card alone)
	scripts/render-icon.sh $(ARGS)

dev-cert:  ## Create the self-signed "Worklens Dev" certificate (once per Mac; asks for your password)
	scripts/make-dev-cert.sh

sign:  ## Codesign the app (uses the "Worklens Dev" certificate if present, else ad-hoc)
	scripts/sign.sh

install:  ## Copy the app to /Applications and put a `worklens` command on PATH
	scripts/install.sh

run:  ## Launch the installed app if there is one, else the bundled one
	scripts/launch.sh

update:  ## Pull, rebuild, re-sign, re-install and relaunch (what the menu's "Update and restart…" runs)
	scripts/update.sh

test:  ## Run the test suite (FILTER=<pattern> runs a subset)
	swift test $(SWIFT_TEST_FLAGS) $(if $(FILTER),--filter "$(FILTER)")

format:  ## Rewrite Sources and Tests with swift-format, using .swift-format
	swift format --in-place --recursive --parallel Sources Tests

format-check:  ## Report swift-format violations without changing anything
	swift format lint --recursive --parallel --strict Sources Tests

lint-strings:  ## Check the localization catalogs: every key the code asks for is in en.lproj
	@scripts/strings-lint.sh

lint-design:  ## Check the design rules: Theme literals, key names in copy, icon buttons
	@scripts/design-lint.sh

test-scripts:  ## Check scripts/build-progress.sh against captured builds, bootstrap's toolchain step against stand-in tools, and the troubleshooting anchors they link to
	@scripts/build-progress-test.sh
	@scripts/bootstrap-test.sh

check: format-check lint-strings lint-design test-scripts test  ## What CI runs: formatting, the catalogs, the design rules, the script checks, then the suite

doctor-toolchain:  ## Check the toolchain traps that have to be true before a build (warns, never fails)
	@scripts/doctor.sh

clean:  ## Remove build products
	rm -rf .build build

install-env:  ## Point an installed app at this checkout: merge ./.env into ~/Library/Application Support/Worklens/.env with DATA_DIR pinned here (ARGS="--data-dir PATH", ARGS=--no-pin, ARGS=--force)
	@./scripts/install-env.sh $(ARGS)

