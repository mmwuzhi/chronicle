#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/chronicle-setup-env.XXXXXX")"
marker="$test_root/source-executed"
goose_log="$test_root/goose.log"

cleanup() {
  case "$test_root" in
    "${TMPDIR:-/tmp}"/chronicle-setup-env.*) rm -rf "$test_root" ;;
    *) echo "Refusing to remove unexpected test directory: $test_root" >&2 ;;
  esac
}
trap cleanup EXIT

mkdir -p "$test_root/api" "$test_root/bin"
cp "$repo_root/Justfile" "$test_root/Justfile"
printf 'DATABASE_URL="$(touch %s)"\n' "$marker" >"$test_root/.env.example"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$test_root/bin/docker"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$test_root/bin/sleep"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "${DATABASE_URL:-}" >"$SETUP_ENV_TEST_GOOSE_LOG"' \
  >"$test_root/bin/goose"
chmod +x "$test_root/bin/docker" "$test_root/bin/sleep" "$test_root/bin/goose"

(
  cd "$test_root"
  PATH="$test_root/bin:$PATH" SETUP_ENV_TEST_GOOSE_LOG="$goose_log" just setup
)

if [[ -e "$marker" ]]; then
  echo "setup executed shell syntax from .env" >&2
  exit 1
fi
test -s "$goose_log"
echo "setup loads generated dotenv data without shell evaluation"
