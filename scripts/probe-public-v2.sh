#!/usr/bin/env bash
set -euo pipefail

base_url=${1:?usage: probe-public-v2.sh <https-base-url>}
host=${base_url#https://}
host=${host%%/*}
probe_id="pay_public_probe_$(date -u +%Y%m%dT%H%M%SZ)"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

curl_args=(--max-time 20 -sS)
if [[ -n ${BARNACLE_EDGE_IP:-} ]]; then
  curl_args+=(--resolve "$host:443:$BARNACLE_EDGE_IP")
fi

status=$(
  curl "${curl_args[@]}" -o "$tmp_dir/health.json" -w '%{http_code}' \
    "$base_url/health"
)
[[ $status == 200 ]]
jq -e '.status == "ok"' "$tmp_dir/health.json" >/dev/null

status=$(
  curl "${curl_args[@]}" -X POST -D "$tmp_dir/challenge.headers" \
    -o "$tmp_dir/challenge.json" -w '%{http_code}' \
    "$base_url/api/multi-compact"
)
[[ $status == 402 ]]

node - "$tmp_dir/challenge.headers" "$tmp_dir/challenge.json" <<'NODE'
const fs = require('fs');
const headers = fs.readFileSync(process.argv[2], 'utf8');
const body = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const encoded = headers.match(/^payment-required:\s*(.+)\r?$/im)?.[1];
if (!encoded) throw new Error('missing payment-required header');
const required = JSON.parse(Buffer.from(encoded, 'base64').toString('utf8'));
const tokens = required.accepts.map(option => option.extra.tokenType).sort();
if (required.x402Version !== 2 || body.x402?.x402Version !== 2) {
  throw new Error('missing x402 v2 challenge');
}
if (JSON.stringify(tokens) !== JSON.stringify(['STX', 'USDCx', 'sBTC'])) {
  throw new Error(`unexpected token set: ${tokens.join(',')}`);
}
if (!required.accepts.every(option => option.network === 'stacks:1')) {
  throw new Error('non-mainnet payment option advertised');
}
NODE

node - "$tmp_dir/challenge.json" "$probe_id" > "$tmp_dir/forged.sig" <<'NODE'
const fs = require('fs');
const challenge = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const accepted = challenge.accepts.find(option => option.extra.tokenType === 'sBTC');
const payload = {
  x402Version: 2,
  resource: challenge.resource,
  accepted,
  payload: { transaction: '0xdeadbeef' },
  extensions: { 'payment-identifier': { info: { id: process.argv[3] } } },
};
process.stdout.write(Buffer.from(JSON.stringify(payload)).toString('base64'));
NODE

status=$(
  curl "${curl_args[@]}" -X POST \
    -H "payment-signature: $(cat "$tmp_dir/forged.sig")" \
    -o "$tmp_dir/forged.json" -w '%{http_code}' \
    "$base_url/api/compact"
)
[[ $status == 400 ]]
jq -e '.code == "PAYMENT_INVALID"' "$tmp_dir/forged.json" >/dev/null

node - "$tmp_dir/challenge.json" "$probe_id" > "$tmp_dir/conflict.sig" <<'NODE'
const fs = require('fs');
const challenge = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const accepted = challenge.accepts.find(option => option.extra.tokenType === 'sBTC');
const payload = {
  x402Version: 2,
  resource: challenge.resource,
  accepted,
  payload: { transaction: '0xcafebabe' },
  extensions: { 'payment-identifier': { info: { id: process.argv[3] } } },
};
process.stdout.write(Buffer.from(JSON.stringify(payload)).toString('base64'));
NODE

status=$(
  curl "${curl_args[@]}" -X POST \
    -H "payment-signature: $(cat "$tmp_dir/conflict.sig")" \
    -o "$tmp_dir/conflict.json" -w '%{http_code}' \
    "$base_url/api/compact"
)
[[ $status == 409 ]]
jq -e '.code == "PAYMENT_INVALID"' "$tmp_dir/conflict.json" >/dev/null

jq -n \
  --arg url "$base_url" \
  --arg paymentIdentifier "$probe_id" \
  --argjson health "$(cat "$tmp_dir/health.json")" \
  --argjson challenge "$(cat "$tmp_dir/challenge.json")" \
  --argjson forged "$(cat "$tmp_dir/forged.json")" \
  --argjson conflict "$(cat "$tmp_dir/conflict.json")" \
  '{
    url: $url,
    paymentIdentifier: $paymentIdentifier,
    health: $health,
    challenge: {
      x402Version: $challenge.x402Version,
      nestedVersion: $challenge.x402.x402Version,
      tokens: [$challenge.accepts[].extra.tokenType] | sort,
      networks: [$challenge.accepts[].network] | unique
    },
    forgedRelayRejection: $forged,
    replayIdentifierConflict: $conflict
  }'
