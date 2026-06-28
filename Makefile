JUST := just

.PHONY: help docker-check setup dev dev-all dev-data down api web desktop-capture desktop-reload desktop-app desktop-e2e orval test lint migrate migrate-new sqlc rag rag-setup rag-backfill rag-test

help:
	@command -v $(JUST) >/dev/null 2>&1 || { echo "just is required. Install with: brew install just"; exit 1; }
	@$(JUST) --list

docker-check setup dev dev-all dev-data down api web desktop-capture desktop-reload desktop-app desktop-e2e orval test lint migrate sqlc rag rag-setup rag-backfill rag-test:
	@command -v $(JUST) >/dev/null 2>&1 || { echo "just is required. Install with: brew install just"; exit 1; }
	@$(JUST) $@

migrate-new:
	@command -v $(JUST) >/dev/null 2>&1 || { echo "just is required. Install with: brew install just"; exit 1; }
	@if [ -z "$(name)" ]; then echo "usage: make migrate-new name=add_foo"; exit 1; fi
	@$(JUST) migrate-new "$(name)"

%:
	@:
