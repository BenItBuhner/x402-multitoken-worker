# x402-multitoken-worker

x402-enabled API endpoints on Cloudflare Workers.

Built using patterns from:
- [x402-api](https://github.com/aibtcdev/x402-api)
- [stx402](https://github.com/whoabuddy/stx402)

## Quick Start

```bash
# Install dependencies
npm install

# Set your recipient address for local dev
# Edit .dev.vars and replace YOUR_STACKS_ADDRESS_HERE with your address

# Start local dev server
npm run dev
```

The server will start at http://localhost:8787

## Payment Tokens

This API accepts payments in:
- sBTC
- STX
- USDCx

## Endpoints

### GET /
- **Description:** Service info
- **Cost:** Free

### GET /health
- **Description:** Health check endpoint
- **Cost:** Free

### POST /api/compact
- **Description:** Return deterministic JSON request metadata for paid callers
- **Cost:** 10 sats
- **Payment Required:** Yes

### POST /api/multi-compact
- **Description:** Return deterministic JSON request metadata for paid callers
- **Cost:** 10 sBTC sats, 1 micro-STX, or 1 USDCx atomic unit
- **Payment Required:** Yes
- **Payment Options:** sBTC, STX, USDCx

## Deployment

### Development Readiness with a Quick Tunnel

For local development, run the Worker with `npm run dev`. If a public callback or
review URL is needed, a Cloudflare Quick Tunnel can expose the local server:

```bash
cloudflared tunnel --url http://localhost:8787
```

A Quick Tunnel is suitable for development checks only. Its generated URL is
temporary and depends on the local process remaining online. It is not evidence
of a stable production deployment, durable DNS, production secret
configuration, or successful payment settlement.

### Set Production Secrets

```bash
# Set your recipient address (where payments will be sent)
wrangler secret put RECIPIENT_ADDRESS
# Enter: SPB2NAB38RKKM32N5SEJB86YCFMWFR70R9YK12V2
```

### Deploy

```bash
# Deploy to staging (testnet)
npm run deploy:staging

# Deploy to production (mainnet)
npm run deploy:production
```

For a stable production deployment, deploy the production Worker, configure
`RECIPIENT_ADDRESS` in that environment, use the intended mainnet relay, and
publish a stable Worker URL or custom domain. Record the deployed URL and run
the acceptance checks below against that URL.

For a production lane, prefer the guarded wrapper after fresh isolated Wrangler
OAuth:

```bash
export BARNACLE_WRANGLER_HOME=/path/to/lane-owned-wrangler-home

# Run in a short-lived tmux window when the remote browser is ready.
./scripts/start-oauth.sh

# If approval is abandoned or the callback state becomes stale, stop the listener.
./scripts/stop-oauth.sh

# After browser approval, complete the returned localhost callback on this host.
./scripts/complete-oauth-callback.sh \
  'http://localhost:8976/oauth/callback?code=...&state=...'

HOME=$BARNACLE_WRANGLER_HOME \
  npx wrangler secret put RECIPIENT_ADDRESS --env production

BARNACLE_RECIPIENT_SECRET_READY=1 \
  ./scripts/deploy-production.sh --deploy
```

The wrapper refuses the global home directory, verifies authenticated Wrangler
state, deploys only after the explicit `--deploy` switch and recipient-secret
acknowledgement, parses the stable `workers.dev` URL, and runs the non-spending
public preflight. Use `./scripts/deploy-production.sh --dry-run` to verify the
isolated authenticated environment without deploying.

## x402 Headers and Payment Flow

### Implemented x402 v2 Headers

The Worker uses the current x402 v2 headers:

| Direction | Header | Purpose |
|-----------|--------|---------|
| Response | `payment-required` | Base64-encoded x402 v2 payment challenge |
| Request | `payment-signature` | Base64-encoded signed x402 v2 payment payload |
| Response | `payment-response` | Base64-encoded relay settlement result after an accepted payment |
| Response | `X-PAYER-ADDRESS` | Payer address extracted from the relay result |

The current flow is:

1. Client makes request without payment header
2. Server returns HTTP 402 with a `payment-required` header and matching JSON body:
   ```json
   {
     "x402Version": 2,
     "resource": {
       "url": "https://service.example/api/compact",
       "mimeType": "application/json"
     },
     "accepts": [{
       "scheme": "exact",
       "network": "stacks:1",
       "amount": "10",
       "asset": "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token",
       "payTo": "SPB2NAB38RKKM32N5SEJB86YCFMWFR70R9YK12V2",
       "maxTimeoutSeconds": 300
     }]
   }
   ```
3. Client signs payment transaction (does NOT broadcast)
4. Client retries with `payment-signature`, a base64-encoded x402 v2 payload containing the signed transaction and selected server-offered requirement
5. Server verifies the selected requirement and settles payment through the relay's x402 v2 `/settle` envelope
6. Server returns a base64-encoded `payment-response`
7. Server returns the protected response

`X-PAYMENT` remains accepted only as a compatibility alias for an encoded v2
signature. Stable deployment acceptance still requires captured paid-path
evidence; fixture tests and malformed-payment probes do not prove mainnet
settlement.

### Replay Locking

The Worker uses a Durable Object binding named `REPLAY_GUARD` for atomic replay
locking. Before relay settlement it reserves the client
`extensions["payment-identifier"].info.id` idempotently: an identical retry is
allowed, while reuse with a changed payload is rejected. After settlement it
reserves the returned transaction ID uniquely before returning paid content, so
one settled transaction cannot unlock multiple calls concurrently.

## Acceptance Evidence

Do not treat a Quick Tunnel URL, a successful deploy command, or a free
`/health` response as proof of paid endpoint readiness. Record evidence from the
stable deployed URL:

1. `GET /health` returns the expected network.
2. An unpaid `POST /api/compact` returns HTTP 402 and the expected sBTC requirement.
3. An unpaid `POST /api/multi-compact` returns HTTP 402 with sBTC, STX, and USDCx options.
4. Paid requests for each advertised settlement path show the submitted payment header, selected token type for the multi-token route, relay settlement response, protected response body, transaction ID, and payer address.
5. x402 v2 acceptance additionally captures `payment-required`, `payment-signature`, and `payment-response`.
6. Negative-path captures cover invalid, expired, underpaid, relay timeout, and retry behavior.

The repository documentation does not claim that paid settlement or the
negative paths have already passed these checks.

## Testing with curl

```bash
# Service info (free)
curl http://localhost:8787/

# Health check (free)
curl http://localhost:8787/health

# Protected endpoint (returns 402)
curl -X POST http://localhost:8787/api/compact
```

```bash
# This endpoint accepts sBTC only.
curl -X POST http://localhost:8787/api/compact

# This endpoint advertises all three settlement paths.
curl -X POST http://localhost:8787/api/multi-compact

# Paid calls submit the base64-encoded x402 v2 payment payload.
curl -X POST \
  -H 'payment-signature: <base64-x402-v2-payload>' \
  -H 'Content-Type: application/json' \
  -d '{}' \
  http://localhost:8787/api/multi-compact
```

## Failure and Retry Behavior

The middleware is intended to return structured errors for payment failures.
These mappings describe the current implementation and must be confirmed with
acceptance captures before production sign-off:

| Condition | Code | HTTP Status | Client behavior |
|-----------|------|-------------|-----------------|
| Invalid signature or payload | `PAYMENT_INVALID` | 400 | Correct the payload and sign again; do not retry the unchanged request. |
| Expired payment or nonce | `PAYMENT_EXPIRED` | 402 | Fetch a fresh requirement and sign a new payment. |
| Underpayment | `AMOUNT_TOO_LOW` | 402 | Fetch the current requirement and sign a payment meeting the minimum. |
| Insufficient wallet balance | `INSUFFICIENT_FUNDS` | 402 | Fund the wallet or use an eligible payment source before signing again. |
| Relay network error or timeout surfaced by `fetch` | `NETWORK_ERROR` | 502 | Respect `Retry-After: 5`; verify relay replay/idempotency behavior before retrying a signed transaction. |
| Relay unavailable response | `RELAY_UNAVAILABLE` | 503 | Respect `Retry-After: 30`; verify relay replay/idempotency behavior before retrying a signed transaction. |
| Other payment processing error | `UNKNOWN_ERROR` | 500 | Respect `Retry-After: 5` and investigate before retrying. |

There is no application-level relay timeout configured in this Worker. A relay
timeout is classified only if the platform `fetch` call rejects with a timeout
or network error. Production acceptance should measure the observed timeout
path and confirm whether retrying the same signed transaction is safe.

## Non-Spending Public Preflight

After deployment, verify the public control plane without constructing or
broadcasting a real payment:

```bash
./scripts/probe-public-v2.sh https://your-worker.example
```

For a development Quick Tunnel with inconsistent DNS, pin a known edge only for
the probe:

```bash
BARNACLE_EDGE_IP=104.16.231.132 \
  ./scripts/probe-public-v2.sh https://generated-name.trycloudflare.com
```

The script checks health, the encoded three-token mainnet challenge, relay
rejection of a structurally valid forged payload, and atomic rejection when a
changed payload reuses the same client payment identifier. It does not prove
successful mainnet settlement and must not be used as a substitute for the
three authorized live-demo txids.

## Production Availability Evidence

After stable deployment, start the production-only monitor:

```bash
BARNACLE_PRODUCTION_LOG=./barnacle-production-liveness.log \
  ./scripts/start-production-monitor.sh https://your-worker.example 300
```

Before submission, audit that log mechanically:

```bash
./scripts/summarize-production-availability.sh \
  ./barnacle-production-liveness.log 300 14
```

Then validate the complete endpoint-bounty evidence bundle:

```bash
cp ACCEPTANCE-EVIDENCE.example.json ACCEPTANCE-EVIDENCE.json
# Fill only from confirmed production evidence, then run:
./scripts/validate-acceptance-evidence.sh ./ACCEPTANCE-EVIDENCE.json
```

The validator independently fetches the required public GitHub repo or gist,
downloads and checksums the published source archive, requires the named USDCx
contract, distinct confirmed txids with matching explorer URLs and non-empty
paid-response artifacts for all three tokens, confirms an initial healthy
production row belongs to the declared URL, records a `>=14` day availability
commitment, and reruns the non-spending stable-URL public preflight. Continue
monitoring after submission and run the separate `300 14` availability audit
after the promised window completes.

After validation, render the deterministic message for the separate signed
AIBTC submission step:

```bash
./scripts/render-bounty-submission-message.sh \
  ./ACCEPTANCE-EVIDENCE.json ./barnacle-endpoint-bounty-submit-message.txt
```

The renderer runs the full validator first and writes atomically. It does not
sign, spend, or submit anything.

Prepare the fixed-bounty submission handoff in dry-run mode:

```bash
./scripts/prepare-bounty-submission.sh \
  ./ACCEPTANCE-EVIDENCE.json ./barnacle-endpoint-bounty-submit-message.txt \
  https://your-public-writeup.example
```

The wrapper always renders through the full validator first, is fixed to bounty
`mpmvuqlz8bfc9790ad94`, and defaults to dry-run. A signed submission additionally
requires `--submit` and
`BARNACLE_BOUNTY_SUBMIT_ACK=mpmvuqlz8bfc9790ad94`. Do not use that mode until
the evidence is real, complete, and separately authorized.

After each separately authorized confirmed mainnet demonstration, record the
txid-linked protected response without performing any signing, payment, or
broadcast from the helper:

```bash
./scripts/record-authorized-demo.sh \
  ./ACCEPTANCE-EVIDENCE.json STX 1 \
  <confirmed-txid> <https-explorer-url-containing-txid> \
  ./evidence/stx-paid-response.json <confirmed-utc>
```

The audit rejects short windows, unhealthy rows, URL changes, non-monotonic
timestamps, and gaps longer than twice the expected monitor interval.

The monitor refuses Quick Tunnel URLs. It records UTC rows only when the stable
URL returns health `200`, multi-token challenge `402`, the exact
`STX,USDCx,sBTC` token set, and mainnet `stacks:1`. Use
`ACCEPTANCE-EVIDENCE.md` to preserve the deployment timestamp, availability
window, source archive, and the three authorized confirmed mainnet settlement
txids.

Transport failures, non-`200`/`402` responses, and malformed challenges are
recorded as unhealthy rows without stopping the long-running monitor. This
preserves an honest availability record through incidents and recoveries.

`./scripts/deploy-production.sh --deploy` starts this supervised tmux monitor by
default after its stable-URL public preflight. Set
`BARNACLE_START_PRODUCTION_MONITOR=0` only when an external supervisor will
start the same production-only monitor immediately.

---

Generated with [@aibtc/mcp-server](https://www.npmjs.com/package/@aibtc/mcp-server) scaffold tool.
