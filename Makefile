# The bundle on disk is "iMessage Relay.app" (matches the display name);
# internal identifiers like the executable, repo, App Support directory,
# and release-artifact filenames stay kebab-case so we don't break tooling.
APP_BUNDLE := iMessage Relay.app

.PHONY: build release app install run clean test info help icon

help: ## Show this help message
	@echo "iMessage Relay - macOS iMessage gateway"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## Build the Swift executable (debug)
	@echo "Building (debug)..."
	@cd src && swift build
	@echo "Built: src/.build/debug/ImsgRelay"

release: ## Build the Swift executable (release)
	@echo "Building (release)..."
	@cd src && swift build -c release
	@echo "Built: src/.build/release/ImsgRelay"

app: ## Build the .app bundle (release)
	@echo "Building app bundle..."
	@./create-app-bundle.sh
	@echo "App bundle ready: $(APP_BUNDLE)"

install: app ## Install the .app to /Applications
	@echo "Installing to /Applications..."
	@rm -rf "/Applications/$(APP_BUNDLE)"
	@cp -R "$(APP_BUNDLE)" /Applications/
	@echo "Installed: /Applications/$(APP_BUNDLE)"

run: app ## Build and launch the app
	@open "$(APP_BUNDLE)"

test: ## Run Swift unit tests
	@cd src && swift test

icon: ## Regenerate AppIcon.icns from assets/Icon-macOS-Default-1024x1024@2x.png
	@echo "Regenerating AppIcon.icns from source artwork..."
	@SRC="assets/Icon-macOS-Default-1024x1024@2x.png"; \
	WORK=$$(mktemp -d)/AppIcon.iconset; \
	mkdir -p "$$WORK"; \
	for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do \
	  size=$${pair%% *}; name=$${pair##* }; \
	  sips -z $$size $$size "$$SRC" --out "$$WORK/icon_$$name.png" > /dev/null; \
	done; \
	iconutil -c icns "$$WORK" -o src/Sources/Resources/AppIcon.icns; \
	echo "Wrote src/Sources/Resources/AppIcon.icns ($$(ls -la src/Sources/Resources/AppIcon.icns | awk '{print $$5}') bytes)"

clean: ## Remove build artifacts
	@rm -rf src/.build
	@rm -rf "$(APP_BUNDLE)"
	@rm -rf src/Sources/Resources/cloudflared
	@echo "Cleaned."

info: ## Show project info
	@echo "Project: iMessage Relay (repo: imsg-relay)"
	@echo "Swift:   6.0+"
	@echo "Target:  macOS 14+"
	@find src/Sources -name '*.swift' -exec wc -l {} + | tail -1 | awk '{print "Lines:   " $$1 " Swift LOC"}'
