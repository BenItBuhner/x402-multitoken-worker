#!/usr/bin/env bash
set -euo pipefail

base_url=${1:?usage: monitor-production.sh <https-base-url> [interval-seconds] [--once]}
interval_seconds=${2:-300}
mode=${3:-}
log=${BARNACLE_PRODUCTION_LOG:-./barnacle-production-liveness.log}
max_checks=${BARNACLE_MONITOR_MAX_CHECKS:-0}

if [[ $base_url != https://* ]]; then
  printf 'production monitor requires an https URL.\n' >&2
  exit 2
fi
if [[ $base_url == *.trycloudflare.com* ]]; then
  printf 'refusing Quick Tunnel URL; production monitor requires a durable deployment.\n' >&2
  exit 2
fi
if [[ $mode != '' && $mode != --once ]]; then
  printf 'usage: %s <https-base-url> [interval-seconds] [--once]\n' "$0" >&2
  exit 2
fi
if [[ ! $interval_seconds =~ ^[0-9]+$ || ! $max_checks =~ ^[0-9]+$ ]]; then
  printf 'interval-seconds and BARNACLE_MONITOR_MAX_CHECKS must be non-negative integers.\n' >&2
  exit 2
fi
if (( interval_seconds == 0 && max_checks == 0 )) && [[ $mode != --once ]]; then
  printf 'zero-second interval requires --once or bounded BARNACLE_MONITOR_MAX_CHECKS.\n' >&2
  exit 2
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

check_once() {
  local health_status
  local challenge_status
  local tokens
  local networks

  : > "$tmp_dir/health.json"
  : > "$tmp_dir/challenge.json"
  if ! health_status=$(
    curl --max-time 20 -sS \
      -o "$tmp_dir/health.json" \
      -w '%{http_code}' \
      "$base_url/health"
  ); then
    health_status=${health_status:-000}
  fi
  if ! challenge_status=$(
    curl --max-time 20 -sS \
      -X POST \
      -o "$tmp_dir/challenge.json" \
      -w '%{http_code}' \
      "$base_url/api/multi-compact"
  ); then
    challenge_status=${challenge_status:-000}
  fi
  tokens=$(jq -r '[.accepts[].extra.tokenType] | sort | join(",")' "$tmp_dir/challenge.json" 2>/dev/null) \
    || tokens=invalid
  networks=$(jq -r '[.accepts[].network] | unique | sort | join(",")' "$tmp_dir/challenge.json" 2>/dev/null) \
    || networks=invalid

  if [[ $health_status != 200 || $challenge_status != 402 ]]; then
    printf '%s\turl=%s\thealth=%s\tchallenge=%s\ttokens=%s\tnetworks=%s\tstatus=unhealthy\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$base_url" "$health_status" "$challenge_status" "$tokens" "$networks" \
      | tee -a "$log"
    return 1
  fi
  if [[ $tokens != STX,USDCx,sBTC || $networks != stacks:1 ]]; then
    printf '%s\turl=%s\thealth=%s\tchallenge=%s\ttokens=%s\tnetworks=%s\tstatus=unexpected-challenge\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$base_url" "$health_status" "$challenge_status" "$tokens" "$networks" \
      | tee -a "$log"
    return 1
  fi

  printf '%s\turl=%s\thealth=%s\tchallenge=%s\ttokens=%s\tnetworks=%s\tstatus=healthy\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$base_url" "$health_status" "$challenge_status" "$tokens" "$networks" \
    | tee -a "$log"
}

checks=0
while true; do
  check_status=0
  check_once || check_status=$?
  checks=$((checks + 1))
  [[ $mode == --once ]] && exit "$check_status"
  (( max_checks > 0 && checks >= max_checks )) && exit 0
  sleep "$interval_seconds"
done
