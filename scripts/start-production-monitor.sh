#!/usr/bin/env bash
set -euo pipefail

base_url=${1:?usage: start-production-monitor.sh <https-base-url> [interval-seconds]}
interval_seconds=${2:-300}
session=${BARNACLE_PRODUCTION_MONITOR_SESSION:-barnacle_production_liveness}
log=${BARNACLE_PRODUCTION_LOG:-./barnacle-production-liveness.log}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ ! $session =~ ^[A-Za-z0-9_.-]+$ ]]; then
  printf 'BARNACLE_PRODUCTION_MONITOR_SESSION contains unsupported characters.\n' >&2
  exit 2
fi
if ! command -v tmux >/dev/null; then
  printf 'tmux is required to supervise the production availability monitor.\n' >&2
  exit 2
fi
if tmux has-session -t "=$session" 2>/dev/null; then
  printf 'production monitor session already exists: %s\n' "$session" >&2
  exit 2
fi

mkdir -p "$(dirname "$log")"
log_dir=$(cd "$(dirname "$log")" && pwd)
log="$log_dir/$(basename "$log")"

# Refuse bad URLs and establish the first healthy row before backgrounding.
BARNACLE_PRODUCTION_LOG=$log \
  "$script_dir/monitor-production.sh" "$base_url" "$interval_seconds" --once

printf -v monitor_command 'exec env BARNACLE_PRODUCTION_LOG=%q %q %q %q' \
  "$log" "$script_dir/monitor-production.sh" "$base_url" "$interval_seconds"
tmux new-session -d -s "$session" "$monitor_command"

if ! tmux has-session -t "=$session" 2>/dev/null; then
  printf 'production monitor session did not remain active: %s\n' "$session" >&2
  exit 1
fi

printf 'barnacle_production_monitor_started\tsession=%s\tlog=%s\turl=%s\n' \
  "$session" "$log" "$base_url"
