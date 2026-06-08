# The bundle on disk is "iMessage Relay.app" (matches the display name);
# internal identifiers like the executable, repo, App Support directory,
# and release-artifact filenames stay kebab-case so we don't break tooling.
APP_BUNDLE := iMessage Relay.app

.PHONY: build release app install run clean test info help

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
