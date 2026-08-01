#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${SELFHOST_ENV_FILE:-$repo_root/.env.selfhost}"
compose_file="$repo_root/docker-compose.selfhost.yml"
action="${1:-up}"
export SELFHOST_ENV_FILE="$env_file"

init_env() {
  if [[ -f "$env_file" ]]; then
    return
  fi
  postgres_password="$(openssl rand -hex 24)"
  jwt_secret="$(openssl rand -hex 48)"
  minio_user="$(openssl rand -hex 12)"
  minio_password="$(openssl rand -hex 32)"
  sed \
    -e "s/__POSTGRES_PASSWORD__/$postgres_password/g" \
    -e "s/__JWT_SECRET__/$jwt_secret/g" \
    -e "s/__MINIO_ROOT_USER__/$minio_user/g" \
    -e "s/__MINIO_ROOT_PASSWORD__/$minio_password/g" \
    "$repo_root/.env.selfhost.example" >"$env_file"
  chmod 0600 "$env_file"
  echo "Created $env_file. Review PUBLIC_URL and WEBAUTHN_RP_ID before internet-facing use."
}

init_env
compose=(
  docker compose
  --project-name "${SELFHOST_PROJECT_NAME:-chronicle-selfhost}"
  --env-file "$env_file"
  -f "$compose_file"
)
if [[ "${SELFHOST_RAG:-0}" == "1" ]]; then
  compose+=(--profile rag)
fi

case "$action" in
  init)
    echo "Self-host configuration is ready at $env_file."
    ;;
  up)
    "${compose[@]}" up -d --build
    "${compose[@]}" ps
    ;;
  down)
    "${compose[@]}" down
    ;;
  logs)
    "${compose[@]}" logs -f --tail=200
    ;;
  backup)
    if [[ -z "${CHRONICLE_ACCESS_TOKEN:-}" ]]; then
      echo "CHRONICLE_ACCESS_TOKEN is required to include the portable Chronicle archive." >&2
      exit 2
    fi
    backup_root="${SELFHOST_BACKUP_ROOT:-$repo_root/backups/$(date -u +%Y%m%dT%H%M%SZ)}"
    if [[ -z "$backup_root" || "$backup_root" != /* || "$backup_root" == "/" || -L "$backup_root" ]]; then
      echo "Refusing unsafe backup destination." >&2
      exit 2
    fi
    if [[ -e "$backup_root" ]]; then
      echo "Refusing to overwrite existing backup destination." >&2
      exit 2
    fi
    backup_parent="$(dirname "$backup_root")"
    mkdir -p "$backup_parent"
    backup_stage="$(mktemp -d "${backup_root}.partial.XXXXXXXX")"
    chmod 0700 "$backup_stage"
    cleanup_stage() {
      if [[ -d "$backup_stage" ]]; then
        find "$backup_stage" -depth -delete
      fi
    }
    trap cleanup_stage EXIT
    api_stopped=0
    web_stopped=0
    restore_services() {
      if [[ "$api_stopped" == "1" ]]; then
        "${compose[@]}" start api >/dev/null
      fi
      if [[ "$web_stopped" == "1" ]]; then
        "${compose[@]}" start web >/dev/null
      fi
      cleanup_stage
    }
    trap restore_services EXIT
    "${compose[@]}" stop web
    web_stopped=1
    "${compose[@]}" exec -T \
      -e "ARCHIVE_TOKEN=$CHRONICLE_ACCESS_TOKEN" \
      api sh -c \
      'wget -qO- --header="Authorization: Bearer $ARCHIVE_TOKEN" http://localhost:8080/archive/export' \
      >"$backup_stage/chronicle.zip"
    "${compose[@]}" stop api
    api_stopped=1
    "${compose[@]}" exec -T postgres \
      pg_dump -U chronicle -d chronicle -Fc >"$backup_stage/postgres.dump"
    "${compose[@]}" cp minio:/data "$backup_stage/minio-data"
    tar -czf "$backup_stage/media.tar.gz" -C "$backup_stage/minio-data" .
    unzip -tq "$backup_stage/chronicle.zip" >/dev/null
    "${compose[@]}" exec -T postgres pg_restore --list \
      <"$backup_stage/postgres.dump" >/dev/null
    tar -tzf "$backup_stage/media.tar.gz" >/dev/null
    chmod 0600 \
      "$backup_stage/postgres.dump" \
      "$backup_stage/chronicle.zip" \
      "$backup_stage/media.tar.gz"
    chmod -R go-rwx "$backup_stage/minio-data"
    (
      cd "$backup_stage"
      shasum -a 256 postgres.dump chronicle.zip media.tar.gz >checksums.sha256
    )
    touch "$backup_stage/COMPLETE"
    "${compose[@]}" start api >/dev/null
    api_stopped=0
    "${compose[@]}" start web >/dev/null
    web_stopped=0
    mv "$backup_stage" "$backup_root"
    trap - EXIT
    echo "Backup written to $backup_root"
    ;;
  *)
    echo "usage: $0 {init|up|down|logs|backup}" >&2
    exit 2
    ;;
esac
