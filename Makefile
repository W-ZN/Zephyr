# Zephyr developer entry points. Shared libraries (sources/) build with SwiftPM; each client
# platform has its own host under apps/<platform> (only macOS today).
#
# Everything stays inside this folder, in two places besides the sources. dist/ is what is kept:
# the packaged products at its top (today the signed Zephyr.app and the release disk image; later
# platforms' packages beside them), the one copy that runs, is tested and is registered with macOS,
# and dist/archive/ for everything retained (older app packages, evidence per round, design assets,
# old material). build.noindex/ is what can be rebuilt and deleted at any time: Xcode's DerivedData,
# SwiftPM (spm/), tools such as XcodeGen, the app's own data when run from here (home/, via
# CFFIXED_USER_HOME), what the checks write (output/) and disk image staging (dmg/). The signing
# keychain lives in .signing/. Nothing is installed globally unless you run `make install`.

ROOT      := $(CURDIR)
BUILD     := $(ROOT)/build.noindex
DIST      := $(ROOT)/dist
DERIVED   := $(BUILD)/DerivedData
CONFIG    ?= Release
MACOS     := $(ROOT)/apps/macos
BUILT     := $(DERIVED)/Build/Products/$(CONFIG)/Zephyr.app
APP       := $(DIST)/Zephyr.app
XCODEGEN  := $(BUILD)/tools/xcodegen/bin/xcodegen
SANDBOX_HOME := $(BUILD)/home
OUT       := $(BUILD)/output
SPM_FLAGS := --scratch-path $(BUILD)/spm/scratch --cache-path $(BUILD)/spm/cache \
             --config-path $(BUILD)/spm/config --security-path $(BUILD)/spm/security
# Package checkouts land in $(DERIVED)/SourcePackages. (-clonedSourcePackagesDirPath left the local
# package unresolved with Xcode 27, so the derived-data default is used instead.)
XCB_FLAGS := -project $(MACOS)/Zephyr.xcodeproj -scheme Zephyr -configuration $(CONFIG) -derivedDataPath $(DERIVED) \
             CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# The check scripts use only the standard library: any Python 3 works (make save-check PYTHON=...).
PYTHON    ?= python3

.PHONY: all test window-check save-check agent-check corpus bench project xcode build sign signing-init dmg run snapshot ql-register ql-unregister install clean

all: build

# Shared libraries and their tests (tests/).
test:
	swift test $(SPM_FLAGS)

# Actual AppKit window routing, expand/restore and sidebar clicks; run after a Release build.
window-check:
	zsh "$(ROOT)/tests/window/check-window.sh"

# Byte-exact saves through the built app: BOM, CRLF, mixed line breaks, Unicode, invalid UTF-8 (design §5).
save-check:
	mkdir -p $(SANDBOX_HOME)
	$(PYTHON) tests/save/check-save.py "$(APP)" $(OUT)/save-check $(SANDBOX_HOME)

# Agent access through the built app and CLI: read, search, proposals, recovery records, refusal (design §11).
agent-check:
	mkdir -p $(SANDBOX_HOME)
	$(PYTHON) tests/agent/check-agent.py "$(APP)" $(OUT)/agent-check $(SANDBOX_HOME)

# Fixed benchmark corpus and the app's bench mode over it (design §3.4).
corpus:
	$(PYTHON) tests/bench/make-corpus.py $(OUT)/corpus

# make bench [FILES="prose-1mb math-900"] [RUNS=3] [LIMIT=300] [FULL=NO] [CANVAS=block|source]
bench: corpus
	PYTHON=$(PYTHON) RUNS=$(or $(RUNS),3) LIMIT=$(or $(LIMIT),300) FULL=$(or $(FULL),YES) CANVAS=$(CANVAS) tests/bench/run-bench.sh "$(APP)" $(OUT)/corpus $(OUT)/bench $(SANDBOX_HOME) $(FILES)

# --- macOS client (apps/macos) ---------------------------------------------------------------

$(XCODEGEN):
	ROOT=$(ROOT) $(MACOS)/scripts/bootstrap.sh

project: $(XCODEGEN)
	$(XCODEGEN) generate --quiet --spec $(MACOS)/project.yml

xcode: project
	open $(MACOS)/Zephyr.xcodeproj

# Builds in build.noindex, then moves the app to dist/Zephyr.app and signs it there. Xcode
# registers its build product with LaunchServices; that path is unregistered and emptied, so the
# checkout holds a single Zephyr.app and the Dock, Finder and `open` always find it.
build: project
	xcodebuild $(XCB_FLAGS) build -quiet
	-$(LSREGISTER) -u "$(BUILT)" 2>/dev/null
	rm -rf "$(APP)" && mkdir -p "$(DIST)"
	mv "$(BUILT)" "$(APP)"
	$(MAKE) sign
	$(LSREGISTER) -f "$(APP)"

# Self-signed identity from the project keychain when it exists (make signing-init), ad-hoc otherwise.
sign:
	ROOT=$(ROOT) $(MACOS)/scripts/sign.sh "$(APP)"

signing-init:
	ROOT=$(ROOT) $(MACOS)/scripts/signing-init.sh

# Release disk image: a copy of the built app with the third-party licenses, signed ad-hoc (no
# Developer ID, not notarized), next to an Applications link: dist/Zephyr-<version>.dmg.
VERSION := $(shell awk -F'"' '/MARKETING_VERSION/ { print $$2; exit }' $(MACOS)/project.yml)
dmg: build
	ROOT=$(ROOT) $(MACOS)/scripts/make-dmg.sh "$(APP)" "$(DIST)/Zephyr-$(VERSION).dmg" "$(DERIVED)/SourcePackages/checkouts"

run:
	mkdir -p $(SANDBOX_HOME)
	CFFIXED_USER_HOME=$(SANDBOX_HOME) "$(APP)/Contents/MacOS/Zephyr" $(ARGS)

# Render a document to PNG without showing a window: make snapshot FILE=path/to/doc.md NAME=doc
snapshot:
	mkdir -p $(SANDBOX_HOME) $(OUT)/snapshots
	CFFIXED_USER_HOME=$(SANDBOX_HOME) "$(APP)/Contents/MacOS/Zephyr" -ZephyrOpen "$(FILE)" -ZephyrSnapshot "$(OUT)/snapshots/$(NAME).png" $(ARGS)

# Quick Look: register the extension of the built app with LaunchServices / PlugInKit.
ql-register:
	$(LSREGISTER) -f -R "$(APP)"
	pluginkit -a "$(APP)/Contents/PlugIns/ZephyrQuickLook.appex"
	pluginkit -e use -i dev.zephyr.Zephyr.QuickLook
	qlmanage -r >/dev/null && qlmanage -r cache >/dev/null

ql-unregister:
	-pluginkit -r "$(APP)/Contents/PlugIns/ZephyrQuickLook.appex"
	-$(LSREGISTER) -u "$(APP)"
	-qlmanage -r >/dev/null

# Explicit opt-in: copies the app to ~/Applications.
install:
	ditto "$(APP)" "$(HOME)/Applications/Zephyr.app"

# Removes what the build can make again. dist/archive/ (retained content) is never touched.
clean: ql-unregister
	rm -rf $(DERIVED) $(APP) $(DIST)/Zephyr-*.dmg $(DIST)/Zephyr-*.dmg.sha256 $(OUT) $(MACOS)/Zephyr.xcodeproj
