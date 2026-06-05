API_DIR := api
WEB_DIR := web
DESKTOP_DIR := desktop
MIGRATIONS := $(API_DIR)/db/migrations

-include .env
export

.PHONY: help dev dev-data down api web desktop-capture orval test lint migrate migrate-new sqlc setup

help:
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

setup: ## first-time setup: copy .env, start data layer, run migrations
	@test -f .env || cp .env.example .env
	docker compose up -d postgres redis
	sleep 3
	set -a && . ./.env && set +a && cd $(API_DIR) && goose -dir db/migrations postgres "$$DATABASE_URL" up

dev: ## start full stack (docker compose watch)
	docker compose watch

dev-data: ## start only postgres + redis
	docker compose up -d postgres redis

down: ## stop and remove all dev containers
	docker compose down

api: dev-data ## run API server locally (starts postgres + redis if needed)
	@lsof -ti :$(PORT) | xargs kill -9 2>/dev/null || true
	cd $(API_DIR) && go run cmd/server/main.go

web: ## run Vite dev server
	cd $(WEB_DIR) && pnpm dev

desktop-capture: ## run the macOS menu bar quick-capture app
	cd $(DESKTOP_DIR) && swift run ChronicleDesktop

orval: ## regenerate typed API hooks (API server must be running)
	cd $(WEB_DIR) && pnpm orval

test: ## run all Go tests (serial)
	cd $(API_DIR) && go test -p 1 ./...

lint: ## vet + staticcheck the API
	cd $(API_DIR) && go vet ./... && staticcheck ./...

migrate: ## apply pending migrations
	cd $(API_DIR) && goose -dir db/migrations postgres "$$DATABASE_URL" up

migrate-new: ## create a new migration  usage: make migrate-new name=add_foo
	cd $(API_DIR) && goose -dir db/migrations postgres "$$DATABASE_URL" create $(name) sql

sqlc: ## regenerate db/sqlc/ from db/queries/
	cd $(API_DIR) && sqlc generate
