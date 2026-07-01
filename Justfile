set dotenv-load
set export
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

api_dir := "api"
web_dir := "web"
desktop_dir := "desktop"
rag_dir := "ragsvc"
rag_port := env_var_or_default("RAG_PORT", "5400")
desktop_build_config := env_var_or_default("DESKTOP_BUILD_CONFIG", "debug")
docker_start_timeout := env_var_or_default("DOCKER_START_TIMEOUT", "60")

_default:
    @just --list

# first-time setup: copy .env, start data layer, run migrations
setup: docker-check
    @test -f .env || cp .env.example .env
    docker compose up -d postgres redis
    sleep 3
    cd {{ api_dir }} && goose -dir db/migrations postgres "$DATABASE_URL" up

# start full stack (docker compose watch)
dev: docker-check
    @interrupted=0; \
    trap 'interrupted=1' INT TERM; \
    set +e; \
    docker compose watch 2> >(grep -v -E 'context canceled|operation canceled' >&2); \
    status=$?; \
    set -e; \
    if [ "$interrupted" -eq 1 ] || [ "$status" -eq 130 ] || [ "$status" -eq 143 ]; then \
      exit 0; \
    fi; \
    exit "$status"

# build/reload the macOS app, then start docker backend+web+data with watch
dev-all: docker-check desktop-reload
    @interrupted=0; \
    trap 'interrupted=1' INT TERM; \
    set +e; \
    docker compose watch 2> >(grep -v -E 'context canceled|operation canceled' >&2); \
    status=$?; \
    set -e; \
    if [ "$interrupted" -eq 1 ] || [ "$status" -eq 130 ] || [ "$status" -eq 143 ]; then \
      exit 0; \
    fi; \
    exit "$status"

# start only postgres + redis
dev-data: docker-check
    docker compose up -d postgres redis

# stop and remove all dev containers
down: docker-check
    docker compose down

# run API server locally (starts postgres + redis if needed)
api: dev-data
    @lsof -ti :${PORT:-8080} | xargs kill -9 2>/dev/null || true
    @interrupted=0; \
    trap 'interrupted=1' INT TERM; \
    set +e; \
    cd {{ api_dir }} && go run cmd/server/main.go; \
    status=$?; \
    set -e; \
    if [ "$interrupted" -eq 1 ] || [ "$status" -eq 130 ] || [ "$status" -eq 143 ]; then \
      exit 0; \
    fi; \
    exit "$status"

# run Vite dev server
web:
    @interrupted=0; \
    trap 'interrupted=1' INT TERM; \
    set +e; \
    cd {{ web_dir }} && pnpm dev; \
    status=$?; \
    set -e; \
    if [ "$interrupted" -eq 1 ] || [ "$status" -eq 130 ] || [ "$status" -eq 143 ]; then \
      exit 0; \
    fi; \
    exit "$status"

# run the macOS menu bar quick-capture app
desktop-capture:
    @echo "Starting ChronicleDesktop in the menu bar. Press Ctrl+C here to stop the dev run."
    @trap 'exit 0' INT TERM; cd {{ desktop_dir }} && swift run ChronicleDesktop

# rebuild and relaunch the macOS menu bar app only when it changed
desktop-reload:
    cd {{ desktop_dir }} && bash scripts/reload-app.sh {{ desktop_build_config }}

# build the macOS .app bundle (required for reminder notifications)
desktop-app:
    cd {{ desktop_dir }} && bash scripts/build-app.sh

# run the macOS desktop smoke E2E tests
desktop-e2e:
    cd {{ desktop_dir }} && bash scripts/e2e.sh

# regenerate typed API hooks (API server must be running)
orval:
    cd {{ web_dir }} && pnpm orval

# run all Go tests (serial)
test:
    cd {{ api_dir }} && go test -p 1 ./...

# vet + staticcheck the API
lint:
    cd {{ api_dir }} && go vet ./... && staticcheck ./...

# apply pending migrations
migrate:
    cd {{ api_dir }} && goose -dir db/migrations postgres "$DATABASE_URL" up

# create a new migration. usage: just migrate-new add_foo
migrate-new name:
    cd {{ api_dir }} && goose -dir db/migrations postgres "$DATABASE_URL" create "{{ name }}" sql

# regenerate db/sqlc/ from db/queries/
sqlc:
    cd {{ api_dir }} && sqlc generate

# create the ragsvc venv and install deps
rag-setup:
    cd {{ rag_dir }} && python3 -m venv .venv && .venv/bin/pip install -q --upgrade pip && .venv/bin/pip install -q -r requirements.txt

# run the Python RAG sidecar (embeddings + retrieval + analysis)
rag: dev-data
    @test -d {{ rag_dir }}/.venv || just rag-setup
    @interrupted=0; \
    trap 'interrupted=1' INT TERM; \
    set +e; \
    cd {{ rag_dir }} && .venv/bin/python app.py; \
    status=$?; \
    set -e; \
    if [ "$interrupted" -eq 1 ] || [ "$status" -eq 130 ] || [ "$status" -eq 143 ]; then \
      exit 0; \
    fi; \
    exit "$status"

# index + extract all existing captures (RAG sidecar must be running)
rag-backfill:
    curl -fsS -X POST http://localhost:{{ rag_port }}/backfill && echo

# run ragsvc pure-logic tests
rag-test:
    @test -d {{ rag_dir }}/.venv || just rag-setup
    cd {{ rag_dir }} && .venv/bin/python -m pytest -q

docker-check:
    #!/usr/bin/env bash
    set -euo pipefail
    if docker info >/dev/null 2>&1; then
      exit 0
    fi

    echo "Docker is not reachable. Starting OrbStack..."
    if ! open -ga OrbStack >/dev/null 2>&1; then
      echo "Could not start OrbStack. Start OrbStack or Docker Desktop, then retry."
      exit 1
    fi

    i=0
    while ! docker info >/dev/null 2>&1; do
      if [ "$i" -ge {{ docker_start_timeout }} ]; then
        echo "Docker did not become ready within {{ docker_start_timeout }}s."
        exit 1
      fi
      sleep 1
      i=$((i + 1))
    done
