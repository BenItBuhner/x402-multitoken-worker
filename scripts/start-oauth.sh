#!/usr/bin/env bash
set -euo pipefail

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

if ss -ltn '( sport = :8976 )' | tail -n +2 | grep -q .; then
  printf 'refusing OAuth start: callback port 8976 is already in use; inspect it and run ./scripts/stop-oauth.sh only for a stale Wrangler listener.\n' >&2
  exit 2
fi

export BROWSER=echo
exec npx wrangler login --callback-host=127.0.0.1
