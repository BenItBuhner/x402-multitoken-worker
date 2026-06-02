#!/usr/bin/env bash
set -euo pipefail

evidence=${1:?usage: record-authorized-demo.sh <acceptance-evidence.json> <STX|USDCx|sBTC> <amount-atomic-units> <confirmed-txid> <explorer-url> <protected-response-artifact> <confirmed-utc>}
token=${2:?usage: record-authorized-demo.sh <acceptance-evidence.json> <STX|USDCx|sBTC> <amount-atomic-units> <confirmed-txid> <explorer-url> <protected-response-artifact> <confirmed-utc>}
amount=${3:?usage: record-authorized-demo.sh <acceptance-evidence.json> <STX|USDCx|sBTC> <amount-atomic-units> <confirmed-txid> <explorer-url> <protected-response-artifact> <confirmed-utc>}
txid=${4:?usage: record-authorized-demo.sh <acceptance-evidence.json> <STX|USDCx|sBTC> <amount-atomic-units> <confirmed-txid> <explorer-url> <protected-response-artifact> <confirmed-utc>}
explorer=${5:?usage: record-authorized-demo.sh <acceptance-evidence.json> <STX|USDCx|sBTC> <amount-atomic-units> <confirmed-txid> <explorer-url> <protected-response-artifact> <confirmed-utc>}
artifact=${6:?usage: record-authorized-demo.sh <acceptance-evidence.json> <STX|USDCx|sBTC> <amount-atomic-units> <confirmed-txid> <explorer-url> <protected-response-artifact> <confirmed-utc>}
confirmed_utc=${7:?usage: record-authorized-demo.sh <acceptance-evidence.json> <STX|USDCx|sBTC> <amount-atomic-units> <confirmed-txid> <explorer-url> <protected-response-artifact> <confirmed-utc>}

if [[ ! -f $evidence ]]; then
  printf 'acceptance evidence file does not exist: %s\n' "$evidence" >&2
  exit 2
fi
case "$token" in
  STX|USDCx|sBTC) ;;
  *)
    printf 'token must be exactly STX, USDCx, or sBTC.\n' >&2
    exit 2
    ;;
esac
if [[ ! $amount =~ ^[1-9][0-9]*$ ]]; then
  printf 'amount-atomic-units must be a positive integer string.\n' >&2
  exit 2
fi
if [[ ! $txid =~ ^(0x)?[0-9a-f]{64}$ ]]; then
  printf 'confirmed-txid must be 64 lowercase hexadecimal characters with optional 0x prefix.\n' >&2
  exit 2
fi
normalized_txid=${txid#0x}
if [[ $explorer != https://* || $explorer != *"$normalized_txid"* ]]; then
  printf 'explorer-url must use HTTPS and contain the confirmed txid.\n' >&2
  exit 2
fi
if [[ ! -s $artifact ]]; then
  printf 'protected-response-artifact is missing or empty: %s\n' "$artifact" >&2
  exit 2
fi
if [[ ! $confirmed_utc =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || ! date -u -d "$confirmed_utc" +%s >/dev/null 2>&1; then
  printf 'confirmed-utc must be a parseable UTC timestamp ending in Z.\n' >&2
  exit 2
fi

evidence_dir=$(cd "$(dirname "$evidence")" && pwd)
artifact_dir=$(cd "$(dirname "$artifact")" && pwd)
artifact="$artifact_dir/$(basename "$artifact")"
case "$artifact" in
  "$evidence_dir"/*) artifact_for_json=${artifact#"$evidence_dir"/} ;;
  *) artifact_for_json=$artifact ;;
esac

if jq -e --arg token "$token" --arg txid "$normalized_txid" '
  [.demonstrations[] | select(.token != $token) | .confirmedTxid | sub("^0x"; "")]
  | index($txid) != null
' "$evidence" >/dev/null; then
  printf 'confirmed-txid is already recorded for a different token.\n' >&2
  exit 2
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
jq \
  --arg token "$token" \
  --arg amount "$amount" \
  --arg txid "$txid" \
  --arg explorer "$explorer" \
  --arg artifact "$artifact_for_json" \
  --arg confirmed "$confirmed_utc" \
  '
    .demonstrations |= map(
      if .token == $token then
        .amountAtomicUnits = $amount
        | .confirmedTxid = $txid
        | .explorerUrl = $explorer
        | .protectedResponseArtifact = $artifact
        | .confirmedUtc = $confirmed
      else
        .
      end
    )
  ' "$evidence" > "$tmp"

if [[ $(jq -er --arg token "$token" '[.demonstrations[] | select(.token == $token)] | length' "$tmp") != 1 ]]; then
  printf 'evidence template must contain exactly one %s demonstration row.\n' "$token" >&2
  exit 2
fi

mv "$tmp" "$evidence"
trap - EXIT
printf 'barnacle_authorized_demo_recorded\ttoken=%s\ttxid=%s\tartifact=%s\n' \
  "$token" "$txid" "$artifact_for_json"
