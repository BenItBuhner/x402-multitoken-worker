#!/usr/bin/env bash
set -euo pipefail

evidence=${1:?usage: validate-acceptance-evidence.sh <acceptance-evidence.json>}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ ! -f $evidence ]]; then
  printf 'acceptance evidence file does not exist: %s\n' "$evidence" >&2
  exit 2
fi
evidence_dir=$(cd "$(dirname "$evidence")" && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

required_string() {
  local selector=$1
  local value
  value=$(jq -er "$selector | select(type == \"string\" and length > 0)" "$evidence") \
    || {
      printf 'missing or invalid evidence field: %s\n' "$selector" >&2
      exit 2
    }
  printf '%s' "$value"
}

required_integer() {
  local selector=$1
  local description=$2
  local value
  value=$(jq -er "$selector" "$evidence") \
    || {
      printf 'missing or invalid evidence field: %s (%s)\n' "$description" "$selector" >&2
      exit 2
    }
  printf '%s' "$value"
}

resolve_evidence_path() {
  local candidate=$1
  if [[ $candidate == /* ]]; then
    printf '%s' "$candidate"
  else
    printf '%s/%s' "$evidence_dir" "$candidate"
  fi
}

production_url=$(required_string '.productionUrl')
deployment_timestamp=$(required_string '.deploymentTimestampUtc')
source_code_url=$(required_string '.sourceCodeUrl')
source_archive_url=$(required_string '.sourceArchiveUrl')
source_archive_sha=$(required_string '.sourceArchiveSha256')
source_mirror_commit=$(required_string '.sourceMirrorCommit')
usdcx_contract=$(required_string '.usdcxContract')
availability_log=$(resolve_evidence_path "$(required_string '.availabilityLog')")
availability_interval=$(
  required_integer \
    '.availabilityIntervalSeconds | select(type == "number" and floor == . and . > 0)' \
    'availabilityIntervalSeconds'
)
availability_commitment_days=$(
  required_integer \
    '.availabilityCommitmentDays | select(type == "number" and floor == . and . >= 14)' \
    'availabilityCommitmentDays'
)

if [[ $production_url != https://* || $production_url == *.trycloudflare.com* ]]; then
  printf 'productionUrl must be durable HTTPS and must not be a Quick Tunnel URL.\n' >&2
  exit 2
fi
if [[ $source_archive_url != https://* ]]; then
  printf 'sourceArchiveUrl must use HTTPS.\n' >&2
  exit 2
fi
if [[ $source_code_url != https://github.com/* && $source_code_url != https://gist.github.com/* ]]; then
  printf 'sourceCodeUrl must be an HTTPS GitHub repository or gist URL.\n' >&2
  exit 2
fi
if [[ ! $source_archive_sha =~ ^[0-9a-f]{64}$ ]]; then
  printf 'sourceArchiveSha256 must be 64 lowercase hexadecimal characters.\n' >&2
  exit 2
fi
if [[ ! $source_mirror_commit =~ ^[0-9a-f]{40}$ ]]; then
  printf 'sourceMirrorCommit must be 40 lowercase hexadecimal characters.\n' >&2
  exit 2
fi
if [[ $source_archive_url != *"$source_mirror_commit"* ]]; then
  printf 'sourceArchiveUrl must be pinned to sourceMirrorCommit.\n' >&2
  exit 2
fi
if [[ ! $usdcx_contract =~ ^S[PM][A-Z0-9]{38,40}[.][a-zA-Z0-9_-]+$ ]]; then
  printf 'usdcxContract must be a Stacks mainnet contract principal.\n' >&2
  exit 2
fi
if [[ ! $deployment_timestamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || ! date -u -d "$deployment_timestamp" +%s >/dev/null 2>&1; then
  printf 'deploymentTimestampUtc is not a parseable UTC timestamp.\n' >&2
  exit 2
fi
if [[ ${BARNACLE_SKIP_PUBLIC_SOURCE_CODE_CHECK:-0} != 1 ]]; then
  curl --max-time 30 -fsSL "$source_code_url" -o "$tmp_dir/source-code-page"
  if [[ ! -s $tmp_dir/source-code-page ]]; then
    printf 'sourceCodeUrl returned an empty response.\n' >&2
    exit 2
  fi
else
  printf 'public_source_code_check_skipped\treason=explicit-test-override\n'
fi
if [[ ${BARNACLE_SKIP_REMOTE_SOURCE_CHECK:-0} != 1 ]]; then
  curl --max-time 60 -fsSL "$source_archive_url" -o "$tmp_dir/source-archive"
  printf '%s  %s\n' "$source_archive_sha" "$tmp_dir/source-archive" | sha256sum -c -
else
  printf 'source_archive_remote_check_skipped\treason=explicit-test-override\n'
fi

token_count=$(jq -er '.demonstrations | length' "$evidence")
if [[ $token_count != 3 ]]; then
  printf 'demonstrations must contain exactly three token rows.\n' >&2
  exit 2
fi
tokens=$(jq -er '[.demonstrations[].token] | sort | join(",")' "$evidence")
if [[ $tokens != STX,USDCx,sBTC ]]; then
  printf 'demonstrations must contain exactly STX, USDCx, and sBTC.\n' >&2
  exit 2
fi
unique_txids=$(jq -er '[.demonstrations[].confirmedTxid | sub("^0x"; "")] | unique | length' "$evidence")
if [[ $unique_txids != 3 ]]; then
  printf 'demonstrations must contain three distinct confirmed txids.\n' >&2
  exit 2
fi

for token in STX USDCx sBTC; do
  row=$(jq -cer --arg token "$token" '.demonstrations[] | select(.token == $token)' "$evidence")
  amount=$(jq -er '.amountAtomicUnits | select(type == "string" and test("^[1-9][0-9]*$"))' <<<"$row")
  txid=$(jq -er '.confirmedTxid | select(type == "string" and test("^(0x)?[0-9a-f]{64}$"))' <<<"$row")
  explorer=$(jq -er '.explorerUrl | select(type == "string" and startswith("https://"))' <<<"$row")
  artifact=$(resolve_evidence_path "$(jq -er '.protectedResponseArtifact | select(type == "string" and length > 0)' <<<"$row")")
  confirmed=$(jq -er '.confirmedUtc | select(type == "string" and length > 0)' <<<"$row")
  if [[ ! $confirmed =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || ! date -u -d "$confirmed" +%s >/dev/null 2>&1; then
    printf '%s confirmedUtc is not a parseable UTC timestamp.\n' "$token" >&2
    exit 2
  fi
  normalized_txid=${txid#0x}
  if [[ $explorer != *"$normalized_txid"* ]]; then
    printf '%s explorerUrl must contain its confirmed txid.\n' "$token" >&2
    exit 2
  fi
  if [[ ! -s $artifact ]]; then
    printf '%s protected response artifact is missing or empty: %s\n' "$token" "$artifact" >&2
    exit 2
  fi
  printf 'demonstration_valid\ttoken=%s\tamount=%s\ttxid=%s\texplorer=%s\tartifact=%s\n' \
    "$token" "$amount" "$txid" "$explorer" "$artifact"
done

if ! availability_summary=$(
  "$script_dir/summarize-production-availability.sh" \
    "$availability_log" "$availability_interval" 0
); then
  printf '%s\n' "$availability_summary"
  printf 'availability audit rejected the evidence bundle.\n' >&2
  exit 2
fi
printf '%s\n' "$availability_summary"
audited_url=$(sed -n 's/^url=//p' <<<"$availability_summary")
if [[ $audited_url != "$production_url" ]]; then
  printf 'availability log URL does not match productionUrl.\n' >&2
  exit 2
fi

if [[ ${BARNACLE_SKIP_PUBLIC_PREFLIGHT:-0} != 1 ]]; then
  "$script_dir/probe-public-v2.sh" "$production_url"
else
  printf 'public_preflight_skipped\treason=explicit-test-override\n'
fi

printf 'barnacle_acceptance_evidence_valid\turl=%s\tsource_sha256=%s\tmirror_commit=%s\n' \
  "$production_url" "$source_archive_sha" "$source_mirror_commit"
printf 'availability_commitment_days=%s\tusdcx_contract=%s\n' \
  "$availability_commitment_days" "$usdcx_contract"
