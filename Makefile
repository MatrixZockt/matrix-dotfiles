SHELL := /bin/bash
.DEFAULT_GOAL := help

# Flatten a multi-line commit message into one line before the shell sees it:
# make hands each recipe LINE to its own shell, so a raw newline inside a variable
# breaks quoting (git then waits in an editor forever). Double quotes are turned
# into single quotes so the message survives "..." quoting in the recipe.
define newline


endef
msg := $(subst ",',$(subst $(newline), ,$(m)))

# ── Working with your Hyprland config ─────────────────────────────────────────
help: ## Show available commands
	@echo "my hyprland config — available commands:"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
	@echo

reload: ## Apply config changes to the running session (shows errors)
	@hyprctl reload >/dev/null 2>&1 || { echo "✖ hyprctl reload failed"; exit 1; }
	@sleep 0.8
	@err="$$(hyprctl configerrors 2>&1)"; \
	if [ -z "$$err" ]; then \
		echo "✔ reloaded — no config errors"; \
	else \
		echo "✖ config errors:"; echo "$$err"; exit 1; \
	fi

check: ## Show errors from the last config load
	@err="$$(hyprctl configerrors 2>&1)"; \
	if [ -z "$$err" ]; then echo "✔ no config errors"; else echo "$$err"; exit 1; fi

keybinds: ## Regenerate docs/KEYBINDS.md from the live session
	@python3 scripts/gen-keybinds-doc.py

status: ## Show what changed in the config
	@git -C $(CURDIR) status --short --branch

save: ## Commit changes: make save m="what you changed"
	@if [ -z "$(msg)" ]; then echo 'usage: make save m="what you changed"'; exit 1; fi
	@git -C $(CURDIR) add -A
	@GIT_EDITOR=true git -C $(CURDIR) commit -m "$(msg)"

push: ## Push commits to GitHub
	@git -C $(CURDIR) push

install: ## Link this repo into ~/.config (safe, backs up conflicts)
	@./install.sh

deps: ## Install the runtime dependencies this config needs (no bloat)
	@./scripts/install-deps.sh

deps-dry: ## Show what `make deps` would install
	@./scripts/install-deps.sh --dry-run

.PHONY: help reload check keybinds status save push install deps deps-dry
