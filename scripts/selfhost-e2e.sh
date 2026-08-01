#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$(mktemp "${TMPDIR:-/tmp}/chronicle-selfhost-e2e.XXXXXX")"
project_name="chronicle-selfhost-e2e"
public_url="http://localhost:18080"
export SELFHOST_ENV_FILE="$env_file"
export SELFHOST_PROJECT_NAME="$project_name"
curl_flags=(--fail-with-body --silent --show-error)

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

cleanup() {
  docker compose \
    --project-name "$project_name" \
    --env-file "$env_file" \
    -f "$repo_root/docker-compose.selfhost.yml" \
    down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -f "$env_file"
}
trap cleanup EXIT

rm -f "$env_file"
"$repo_root/scripts/selfhost.sh" init
sed -i.bak \
  -e 's|^PUBLIC_URL=.*|PUBLIC_URL=http://localhost:18080|' \
  -e 's|^HTTP_PORT=.*|HTTP_PORT=18080|' \
  -e 's|^HTTPS_PORT=.*|HTTPS_PORT=18443|' \
  "$env_file"
rm -f "$env_file.bak"
"$repo_root/scripts/selfhost.sh" up

wait_for_health() {
  for attempt in $(seq 1 60); do
    if curl "${curl_flags[@]}" "$public_url/api/health" >/dev/null 2>&1; then
      return
    fi
    if [[ "$attempt" == "60" ]]; then
      docker compose \
        --project-name "$project_name" \
        --env-file "$env_file" \
        -f "$repo_root/docker-compose.selfhost.yml" logs
      return 1
    fi
    sleep 2
  done
}
wait_for_health

echo "Registering and authenticating through Caddy..."
email="selfhost-e2e-$(date +%s)@example.com"
password="selfhost-e2e-password"
curl "${curl_flags[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$email\",\"password\":\"$password\"}" \
  "$public_url/api/auth/register" >/dev/null
token="$(
  curl "${curl_flags[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$password\"}" \
    "$public_url/api/auth/login" |
    jq -er '.accessToken'
)"
auth_header="Authorization: Bearer $token"

echo "Creating and finding a text Capture..."
capture_id="$(
  curl "${curl_flags[@]}" \
    -H "$auth_header" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: 10cdca29-6868-4d78-b9ab-0c4df6053dcf" \
    -d '{"rawText":"selfhost persistence needle","mediaType":"text","source":"selfhost_e2e"}' \
    "$public_url/api/captures" |
    jq -er '.id'
)"
curl "${curl_flags[@]}" \
  -H "$auth_header" \
  "$public_url/api/find?q=selfhost%20persistence%20needle" |
  jq -e --arg id "$capture_id" '.degraded == true and any(.items[]; .id == $id)' >/dev/null

echo "Uploading and reading Chronicle-managed media..."
media_file="$(mktemp "${TMPDIR:-/tmp}/chronicle-selfhost-media.XXXXXX.png")"
trap 'rm -f "$media_file"; cleanup' EXIT
printf '%s' \
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' |
  openssl base64 -d -A >"$media_file"
media_url="$(
  curl "${curl_flags[@]}" \
    -H "$auth_header" \
    -H "Idempotency-Key: d5be7d8a-e3a3-440f-a7ac-f81360537b78" \
    -F "file=@$media_file;type=image/png" \
    -F "createCapture=true" \
    -F "text=selfhost media persistence" \
    "$public_url/api/captures/upload" |
    jq -er '.mediaUrl'
)"
echo "Reading uploaded media from $media_url"
curl "${curl_flags[@]}" "$media_url" >/dev/null

echo "Downloading and validating a complete archive..."
archive_file="$(mktemp "${TMPDIR:-/tmp}/chronicle-selfhost-archive.XXXXXX.zip")"
trap 'rm -f "$media_file" "$archive_file"; cleanup' EXIT
curl "${curl_flags[@]}" -H "$auth_header" \
  "$public_url/api/archive/export" -o "$archive_file"
unzip -t "$archive_file" >/dev/null
unzip -l "$archive_file" | grep -q 'manifest.json'
unzip -l "$archive_file" | grep -q 'media/'

echo "Running the supported backup workflow..."
backup_parent="$(mktemp -d "${TMPDIR:-/tmp}/chronicle-selfhost-backup.XXXXXX")"
backup_root="$backup_parent/backup"
case "$backup_parent" in
  "${TMPDIR:-/tmp}"/chronicle-selfhost-backup.*) ;;
  *) echo "Unexpected temporary backup path: $backup_root" >&2; exit 2 ;;
esac
trap 'rm -f "$media_file" "$archive_file"; rm -rf "$backup_parent"; cleanup' EXIT
env \
  CHRONICLE_ACCESS_TOKEN="$token" \
  SELFHOST_BACKUP_ROOT="$backup_root" \
  "$repo_root/scripts/selfhost.sh" backup
test -s "$backup_root/postgres.dump"
test -s "$backup_root/media.tar.gz"
test -f "$backup_root/COMPLETE"
unzip -t "$backup_root/chronicle.zip" >/dev/null
(
  cd "$backup_root"
  shasum -a 256 -c checksums.sha256
)
test "$(file_mode "$backup_root")" = "700"
test "$(file_mode "$backup_root/postgres.dump")" = "600"
test "$(file_mode "$backup_root/chronicle.zip")" = "600"
test "$(file_mode "$backup_root/media.tar.gz")" = "600"

echo "Restoring the database backup into an empty verification database..."
compose=(
  docker compose
  --project-name "$project_name"
  --env-file "$env_file"
  -f "$repo_root/docker-compose.selfhost.yml"
)
"${compose[@]}" exec -T postgres dropdb -U chronicle --if-exists chronicle_restore_check
"${compose[@]}" exec -T postgres createdb -U chronicle chronicle_restore_check
"${compose[@]}" exec -T postgres \
  pg_restore -U chronicle -d chronicle_restore_check <"$backup_root/postgres.dump"
restored_capture_count="$(
  "${compose[@]}" exec -T postgres psql -U chronicle -d chronicle_restore_check \
    -Atc "SELECT count(*) FROM captures WHERE raw_text LIKE '%selfhost persistence needle%'"
)"
test "$restored_capture_count" = "1"
restored_media_dir="$backup_parent/restored-media"
mkdir "$restored_media_dir"
tar -xzf "$backup_root/media.tar.gz" -C "$restored_media_dir"
test -n "$(find "$restored_media_dir" -type f -print -quit)"
"${compose[@]}" exec -T postgres dropdb -U chronicle chronicle_restore_check

docker compose \
  --project-name "$project_name" \
  --env-file "$env_file" \
  -f "$repo_root/docker-compose.selfhost.yml" \
  restart postgres minio api web >/dev/null
wait_for_health
echo "Verifying persistence after container restarts..."
curl "${curl_flags[@]}" \
  -H "$auth_header" \
  "$public_url/api/find?q=selfhost%20persistence%20needle" |
  jq -e --arg id "$capture_id" 'any(.items[]; .id == $id)' >/dev/null
curl "${curl_flags[@]}" "$media_url" >/dev/null

echo "Self-host E2E passed."
