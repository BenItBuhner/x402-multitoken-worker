#!/usr/bin/env bash
set -euo pipefail

readonly root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/home"
cat >"$test_root/bin/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ $* == 'wrangler whoami' ]]; then
  printf '%s\n' "${FAKE_WRANGLER_WHOAMI_OUTPUT:-}"
  exit 0
fi

if [[ $* == 'wrangler deploy --dry-run --env production' ]]; then
  printf 'dry-run-called\n' >>"$FAKE_WRANGLER_CALL_LOG"
  exit 0
fi

if [[ $* == 'wrangler secret list --env production' ]]; then
  printf '%s\n' "${FAKE_WRANGLER_SECRET_OUTPUT:-}"
  exit 0
fi

printf 'unexpected npx invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$test_root/bin/npx"

export PATH="$test_root/bin:$PATH"
export BARNACLE_WRANGLER_HOME="$test_root/home"
export FAKE_WRANGLER_CALL_LOG="$test_root/calls.log"

set +e
FAKE_WRANGLER_WHOAMI_OUTPUT='You are not authenticated. Please run `wrangler login`.' \
  "$root/scripts/deploy-production.sh" --dry-run >"$test_root/unauthenticated.log" 2>&1
unauthenticated_status=$?
set -e

if [[ $unauthenticated_status != 2 ]]; then
  printf 'expected unauthenticated dry-run to exit 2, got %s\n' "$unauthenticated_status" >&2
  exit 1
fi
if [[ -e $FAKE_WRANGLER_CALL_LOG ]]; then
  printf 'unauthenticated dry-run reached Wrangler deploy unexpectedly\n' >&2
  exit 1
fi

FAKE_WRANGLER_WHOAMI_OUTPUT='You are logged in with an OAuth Token.' \
  "$root/scripts/deploy-production.sh" --dry-run

if [[ $(<"$FAKE_WRANGLER_CALL_LOG") != dry-run-called ]]; then
  printf 'authenticated dry-run did not reach Wrangler deploy\n' >&2
  exit 1
fi

rm "$FAKE_WRANGLER_CALL_LOG"
set +e
FAKE_WRANGLER_WHOAMI_OUTPUT='You are logged in with an OAuth Token.' \
  BARNACLE_RECIPIENT_SECRET_READY=1 \
  "$root/scripts/deploy-production.sh" --deploy >"$test_root/missing-recipient-secret.log" 2>&1
missing_secret_status=$?
set -e

if [[ $missing_secret_status != 2 ]]; then
  printf 'expected missing-recipient-secret deploy to exit 2, got %s\n' "$missing_secret_status" >&2
  exit 1
fi
if [[ -e $FAKE_WRANGLER_CALL_LOG ]]; then
  printf 'missing-recipient-secret deploy reached Wrangler deploy unexpectedly\n' >&2
  exit 1
fi
if ! rg -q 'RECIPIENT_ADDRESS is not present' "$test_root/missing-recipient-secret.log"; then
  printf 'missing-recipient-secret deploy did not explain refusal\n' >&2
  exit 1
fi

printf 'deploy-production-auth-gate-tests-passed\n'
