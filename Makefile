JUST := just

.PHONY: help docker-check setup dev dev-all dev-data down api web desktop-capture desktop-reload desktop-app desktop-e2e orval test setup-env-test lint migrate migrate-new sqlc rag rag-setup rag-backfill rag-test rag-eval rag-eval-live extension-test extension-e2e extension-package selfhost-up selfhost-down selfhost-logs selfhost-backup

help:
	@command -v $(JUST) >/dev/null 2>&1 || { echo "just is required. Install with: brew install just"; exit 1; }
	@$(JUST) --list

docker-check setup dev dev-all dev-data down api web desktop-capture desktop-reload desktop-app desktop-e2e orval test setup-env-test lint migrate sqlc rag rag-setup rag-backfill rag-test rag-eval rag-eval-live extension-test extension-e2e extension-package selfhost-up selfhost-down selfhost-logs selfhost-backup:
	@command -v $(JUST) >/dev/null 2>&1 || { echo "just is required. Install with: brew install just"; exit 1; }
	@$(JUST) $@

migrate-new:
	@command -v $(JUST) >/dev/null 2>&1 || { echo "just is required. Install with: brew install just"; exit 1; }
	@if [ -z "$(name)" ]; then echo "usage: make migrate-new name=add_foo"; exit 1; fi
	@$(JUST) migrate-new "$(name)"

%:
	@:
