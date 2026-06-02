#!/usr/bin/env bash
set -euo pipefail

readonly oauth_port=8976

mapfile -t listener_pids < <(
  ss -ltnp "( sport = :$oauth_port )" |
    sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' |
    sort -u
)

if [[ ${#listener_pids[@]} -eq 0 ]]; then
  printf 'wrangler_oauth_listener_inactive\n'
  exit 0
fi

for pid in "${listener_pids[@]}"; do
  command=$(ps -p "$pid" -o args=)
  if ! grep -Eqi 'wrangler([^ ]| .*)*login' <<<"$command"; then
    printf 'refusing to stop non-Wrangler OAuth listener pid=%s command=%s\n' "$pid" "$command" >&2
    exit 2
  fi
done

kill "${listener_pids[@]}"

for _ in {1..20}; do
  if ! ss -ltn "( sport = :$oauth_port )" | tail -n +2 | grep -q .; then
    printf 'wrangler_oauth_listener_stopped\n'
    exit 0
  fi
  sleep 0.1
done

printf 'Wrangler OAuth listener remains active on port %s after SIGTERM.\n' "$oauth_port" >&2
exit 1
