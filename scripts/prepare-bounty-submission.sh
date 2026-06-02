#!/usr/bin/env bash
set -euo pipefail

readonly bounty_id=mpmvuqlz8bfc9790ad94
readonly default_submit_helper=/home/bennett/projects/codex-poly-bot-bounty-work/aibtc-mcp-server-audit/scripts/submit-barnacle-aibtc-bounty.mjs

evidence=${1:?usage: prepare-bounty-submission.sh <acceptance-evidence.json> <output-message-file> <content-url> [--submit]}
output=${2:?usage: prepare-bounty-submission.sh <acceptance-evidence.json> <output-message-file> <content-url> [--submit]}
content_url=${3:?usage: prepare-bounty-submission.sh <acceptance-evidence.json> <output-message-file> <content-url> [--submit]}
mode=${4:---dry-run}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ $content_url != https://* ]]; then
  printf 'content-url must use HTTPS.\n' >&2
  exit 2
fi
if [[ $mode != --dry-run && $mode != --submit ]]; then
  printf 'mode must be --dry-run or --submit.\n' >&2
  exit 2
fi

"$script_dir/render-bounty-submission-message.sh" "$evidence" "$output"

if [[ $mode == --dry-run ]]; then
  printf 'barnacle_bounty_submission_dry_run_ready\tbounty=%s\tmessage=%s\tcontent_url=%s\n' \
    "$bounty_id" "$output" "$content_url"
  exit 0
fi

if [[ ${BARNACLE_BOUNTY_SUBMIT_ACK:-} != "$bounty_id" ]]; then
  printf 'refusing signed submission: set BARNACLE_BOUNTY_SUBMIT_ACK=%s for this exact bounty.\n' \
    "$bounty_id" >&2
  exit 2
fi

submit_helper=${BARNACLE_AIBTC_SUBMIT_HELPER:-$default_submit_helper}
if [[ ! -f $submit_helper ]]; then
  printf 'signed submission helper does not exist: %s\n' "$submit_helper" >&2
  exit 2
fi

node "$submit_helper" "$bounty_id" "$output" "$content_url"
