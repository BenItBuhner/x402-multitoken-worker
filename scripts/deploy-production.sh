#!/usr/bin/env bash
set -euo pipefail

mode=${1:---dry-run}
case "$mode" in
  --dry-run|--deploy) ;;
  *)
    printf 'usage: %s [--dry-run|--deploy]\n' "$0" >&2
    exit 2
    ;;
esac

if [[ -z ${BARNACLE_WRANGLER_HOME:-} ]]; then
  printf 'BARNACLE_WRANGLER_HOME is required; use a lane-owned isolated Wrangler home.\n' >&2
  exit 2
fi

mkdir -p "$BARNACLE_WRANGLER_HOME"
export HOME=$BARNACLE_WRANGLER_HOME

if [[ $HOME == "${ORIGINAL_HOME:-/home/bennett}" || $HOME == /home/bennett ]]; then
  printf 'refusing global HOME=%s; use a lane-owned isolated Wrangler home.\n' "$HOME" >&2
  exit 2
fi

npx wrangler whoami >/dev/null

if [[ $mode == --dry-run ]]; then
  npx wrangler deploy --dry-run --env production
  exit 0
fi

if [[ ${BARNACLE_RECIPIENT_SECRET_READY:-} != 1 ]]; then
  cat >&2 <<'EOF'
BARNACLE_RECIPIENT_SECRET_READY=1 is required for deployment.
First run:
  BARNACLE_WRANGLER_HOME=<isolated-home> HOME=<isolated-home> \
    npx wrangler secret put RECIPIENT_ADDRESS --env production
EOF
  exit 2
fi

deploy_log=$(mktemp)
trap 'rm -f "$deploy_log"' EXIT
npx wrangler deploy --env production | tee "$deploy_log"

public_url=$(
  rg -o 'https://[[:alnum:]._-]+[.]workers[.]dev' "$deploy_log" \
    | tail -n 1
)
if [[ -z $public_url ]]; then
  printf 'deployment completed but no workers.dev URL was parsed; inspect Wrangler output.\n' >&2
  exit 1
fi

./scripts/probe-public-v2.sh "$public_url"
if [[ ${BARNACLE_START_PRODUCTION_MONITOR:-1} == 1 ]]; then
  ./scripts/start-production-monitor.sh "$public_url" 300
else
  printf 'barnacle_production_monitor_start_skipped\turl=%s\n' "$public_url"
fi
printf 'barnacle_production_ready\turl=%s\n' "$public_url"
