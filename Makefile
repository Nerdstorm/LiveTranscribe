# Live Transcribe: building, testing, measuring, releasing and looking after the app.
#
# Run `make` from the repository root to list the targets. The README and docs/ say when to use
# each one; docs/releasing.md has the whole release process. Written for the GNU Make 3.81 that
# macOS ships, so it avoids newer features such as .ONESHELL.
#
# Settings, given on the command line:
#   VERSION=x.y.z   the release a release target works on
#   ARGS="..."      extra arguments for bench, eval and train

.DEFAULT_GOAL := help

PACKAGE := Packages/LiveTranscribeKit
APP_BUILD := .build/xcode-app
APP := $(APP_BUILD)/Build/Products/Release/LiveTranscribe.app
# The package's tests and tools build inside the package, into their own copy of the build.
TOOLS := .build/xcode/Build/Products/Release
AUDIO_DIR := $(PACKAGE)/Tests/IntegrationTests/Fixtures/Audio
CLIPS_DIR := $(PACKAGE)/Tests/IntegrationTests/Fixtures/Dictation
NOTARY_PROFILE := $(or $(LT_NOTARY_PROFILE),LiveTranscribe-notary)

# MLX compiles Metal shaders, so everything builds with xcodebuild rather than swift build.
# Skipping plugin validation avoids a prompt to trust mlx-swift's CudaBuild plugin, which only
# does anything in CUDA builds.
XCODE_FLAGS := -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation
PACKAGE_TESTS := xcodebuild test -scheme LiveTranscribeKit-Package $(XCODE_FLAGS) -derivedDataPath .build/xcode

# $(call build-tool,<scheme>): builds one of the package's command-line tools in Release.
build-tool = cd $(PACKAGE) && xcodebuild build -scheme $(1) -configuration Release $(XCODE_FLAGS) \
	-derivedDataPath .build/xcode

# The first line of a release target: stops it unless VERSION is x.y.z.
check-version = @echo '$(VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' \
	|| { echo 'Set VERSION to the release, for example: make $@ VERSION=0.1.0' >&2; exit 2; }

.PHONY: help build run resolve test test-integration prompt-probe audio dictation-audio bench eval \
	train doctor release-test changelog tag release appcast acknowledgements icons logs site clean

help: ## List the targets
	@echo 'Usage: make <target> [VERSION=x.y.z] [ARGS="..."]'
	@awk 'BEGIN { FS = ":.*## " } /^##@ / { printf "\n%s\n", substr($$0, 5) } /^[a-z][a-z-]*:.*## / { printf "  %-18s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

##@ Build and run

build: ## Build the app in Release, into .build/xcode-app
	xcodebuild build -project LiveTranscribe.xcodeproj -scheme LiveTranscribe -configuration Release \
	  $(XCODE_FLAGS) -derivedDataPath $(APP_BUILD)

run: build ## Build the app and open it, quitting this build first if it's running
	@for pid in $$(pgrep -x LiveTranscribe); do \
	  case "$$(ps -o comm= -p $$pid)" in \
	    "$(CURDIR)/$(APP)/"*) kill $$pid; while kill -0 $$pid 2>/dev/null; do sleep 0.2; done ;; \
	    *) echo "Quit the other copy of Live Transcribe first, such as a release in Applications:" \
	         "two copies fight over the shortcut." >&2; exit 1 ;; \
	  esac; \
	done
	open $(APP)

resolve: ## Resolve the Swift packages, which also fetches Sparkle's release tools
	cd $(PACKAGE) && swift package resolve

##@ Test

test: ## Unit tests, which need no models
	cd $(PACKAGE) && $(PACKAGE_TESTS) -skip-testing:IntegrationTests
	scripts/tests/write-changelog-tests.sh

test-integration: audio ## End-to-end tests with the real models, which they download (about 3.5 GB)
	cd $(PACKAGE) && TEST_RUNNER_LT_RUN_MODEL_TESTS=1 $(PACKAGE_TESTS) -only-testing:IntegrationTests

prompt-probe: ## Print the cleanup model's output for hard prompt cases, when changing the prompt
	cd $(PACKAGE) && TEST_RUNNER_LT_PROMPT_PROBE=1 $(PACKAGE_TESTS) -only-testing:IntegrationTests

audio: ## Make the test and bench clips with macOS text-to-speech, if any are missing
	@missing=$$(for text in $(AUDIO_DIR)/*.txt; do [ -f "$${text%.txt}.wav" ] || echo "$$text"; done); \
	if [ -n "$$missing" ]; then scripts/generate-test-audio.sh; \
	else echo "The test and bench clips are there. scripts/generate-test-audio.sh makes them again."; fi

dictation-audio: ## Make the dictation eval clips with macOS text-to-speech, if any are missing
	@missing=$$(awk -F '\t' '$$1 != "" && $$1 !~ /^#/ { print $$1 }' $(CLIPS_DIR)/clips.tsv \
	  | while read -r id; do [ -f "$(CLIPS_DIR)/$$id.wav" ] || echo "$$id"; done); \
	if [ -n "$$missing" ]; then scripts/generate-dictation-audio.sh; \
	else echo "The dictation eval clips are there. scripts/generate-dictation-audio.sh makes them again."; fi

##@ Measure and train

bench: audio ## Live transcript bench: word error rate and latency (ARGS="--level high --fast")
	$(call build-tool,Bench)
	cd $(PACKAGE) && $(TOOLS)/Bench $(ARGS)

eval: dictation-audio ## Dictation eval at every cleanup level (ARGS="--multiline --verbose")
	$(call build-tool,Bench)
	cd $(PACKAGE) && $(TOOLS)/Bench --dictation $(ARGS)

train: ## Run the adapter's Train tool (ARGS="generate", "validate", "train" or "evaluate")
	@[ -n "$(ARGS)" ] || { echo 'Say what to run, for example: make train ARGS="evaluate --no-adapter"' >&2; exit 2; }
	$(call build-tool,Train)
	cd $(PACKAGE) && $(TOOLS)/Train $(ARGS)

##@ Release (docs/releasing.md)

doctor: ## Check the tools and credentials that building and releasing need
	@printf '%-26s' 'Xcode'; xcodebuild -version | head -n 1
	@printf '%-26s' 'Metal Toolchain'; xcrun metal -v >/dev/null 2>&1 && echo 'installed' \
	  || echo 'missing: xcodebuild -downloadComponent MetalToolchain'
	@printf '%-26s' 'Signing your own builds'; [ -f Config/Signing.local.xcconfig ] && echo 'Config/Signing.local.xcconfig' \
	  || echo 'ad-hoc, so macOS asks for permissions after every build (docs/signing.md)'
	@printf '%-26s' 'Developer ID certificate'; security find-identity -v -p codesigning \
	  | grep -q '"Developer ID Application: ' && echo 'in the keychain' || echo 'missing (docs/releasing.md)'
	@printf '%-26s' 'Notary credentials'; xcrun notarytool history --keychain-profile '$(NOTARY_PROFILE)' >/dev/null 2>&1 \
	  && echo '$(NOTARY_PROFILE)' || echo 'missing or not working (docs/releasing.md)'
	@printf '%-26s' 'GitHub CLI'; gh auth status >/dev/null 2>&1 && echo 'signed in' \
	  || echo 'missing or signed out, and make release uploads with it'
	@echo 'make release checks the update signing key, since the keychain may ask before it is read.'

release-test: ## Build HEAD like a release, but ad-hoc signed and not notarized (VERSION=x.y.z)
	$(check-version)
	scripts/release.sh $(VERSION) --test

changelog: ## Summarise the pull requests since the last release into CHANGELOG.md (VERSION=x.y.z)
	$(check-version)
	scripts/write-changelog.sh $(VERSION)

tag: ## Tag main as vVERSION and push the tag, which starts a release (VERSION=x.y.z)
	$(check-version)
	@[ "$$(git branch --show-current)" = main ] || { echo 'Switch to main first: releases are tagged there.' >&2; exit 1; }
	@git fetch -q origin main && [ "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/main)" ] \
	  || { echo "Your main isn't origin's main: pull or push first." >&2; exit 1; }
	git tag -a v$(VERSION) -m 'Live Transcribe $(VERSION)'
	git push origin v$(VERSION)

release: ## Build and notarize tag vVERSION, and upload it as a draft GitHub release (VERSION=x.y.z)
	$(check-version)
	scripts/release.sh $(VERSION) --draft

appcast: ## Once release VERSION is published, offer it as an update by copying its appcast to site/
	$(check-version)
	@[ -f build/release/$(VERSION)/appcast.xml ] \
	  || { echo 'There is no build/release/$(VERSION)/appcast.xml: make release VERSION=$(VERSION) writes it.' >&2; exit 1; }
	@url=$$(xmllint --xpath "string(//item[*[local-name()='shortVersionString']='$(VERSION)']/enclosure/@url)" \
	  build/release/$(VERSION)/appcast.xml); \
	[ -n "$$url" ] || { echo 'The appcast has no entry for $(VERSION).' >&2; exit 1; }; \
	curl -fsL -r 0-0 -o /dev/null "$$url" \
	  || { echo "$$url doesn't download yet. Publish the v$(VERSION) release on GitHub first." >&2; exit 1; }
	cp build/release/$(VERSION)/appcast.xml site/appcast.xml
	@echo 'site/appcast.xml now offers $(VERSION). Merge it into main through a pull request to publish it.'

##@ Maintenance

acknowledgements: ## Rewrite the licence notices in the About panel, after changing a package
	scripts/generate-acknowledgements.sh

icons: ## Render the app's and the website's icons from the SVGs in design/ and site/
	scripts/render-icons.sh

logs: ## Stream the app's log; macOS keeps dictated text redacted
	log stream --level info --style compact --predicate 'subsystem == "org.nerdstorm.LiveTranscribe"'

site: ## Open the website from site/ in your browser
	open site/index.html

clean: ## Delete the app's and the package's builds, but keep release archives and models
	rm -rf $(APP_BUILD) $(PACKAGE)/.build/xcode
