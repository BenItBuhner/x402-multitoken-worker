#!/usr/bin/env bash
set -euo pipefail

evidence=${1:?usage: render-bounty-submission-message.sh <acceptance-evidence.json> <output-file>}
output=${2:?usage: render-bounty-submission-message.sh <acceptance-evidence.json> <output-file>}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

"$script_dir/validate-acceptance-evidence.sh" "$evidence"

evidence_dir=$(cd "$(dirname "$evidence")" && pwd)
availability_log=$(jq -er '.availabilityLog' "$evidence")
if [[ $availability_log != /* ]]; then
  availability_log="$evidence_dir/$availability_log"
fi
availability_interval=$(jq -er '.availabilityIntervalSeconds' "$evidence")
availability_summary=$(
  "$script_dir/summarize-production-availability.sh" \
    "$availability_log" "$availability_interval" 0
)

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

{
  printf 'Barnacle x402 endpoint acceptance evidence\n'
  printf 'Production URL: %s\n' "$(jq -er '.productionUrl' "$evidence")"
  printf 'Deployment UTC: %s\n' "$(jq -er '.deploymentTimestampUtc' "$evidence")"
  printf 'Source code: %s\n' "$(jq -er '.sourceCodeUrl' "$evidence")"
  printf 'Source archive: %s\n' "$(jq -er '.sourceArchiveUrl' "$evidence")"
  printf 'Source SHA-256: %s\n' "$(jq -er '.sourceArchiveSha256' "$evidence")"
  printf 'Source mirror commit: %s\n' "$(jq -er '.sourceMirrorCommit' "$evidence")"
  printf 'USDCx contract: %s\n' "$(jq -er '.usdcxContract' "$evidence")"
  printf 'Availability commitment days: %s\n' "$(jq -er '.availabilityCommitmentDays' "$evidence")"
  printf 'Confirmed production settlements:\n'
  jq -er '
    .demonstrations
    | sort_by(.token)[]
    | "- \(.token): amount=\(.amountAtomicUnits) txid=\(.confirmedTxid) explorer=\(.explorerUrl)"
  ' "$evidence"
  printf 'Availability audit:\n'
  sed 's/^/- /' <<<"$availability_summary"
} > "$tmp"

mkdir -p "$(dirname "$output")"
mv "$tmp" "$output"
trap - EXIT

printf 'barnacle_bounty_submission_message_ready\toutput=%s\n' "$output"
