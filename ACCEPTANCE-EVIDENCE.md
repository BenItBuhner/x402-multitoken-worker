# x402 Multi-Token Endpoint Acceptance Evidence

Complete this only from a durable lane-owned production URL. Do not use a
Quick Tunnel, projected payment, forged payload, or unconfirmed transaction as
acceptance evidence.

Maintain the machine-readable companion file from
`ACCEPTANCE-EVIDENCE.example.json`. Before preparing any signed bounty
submission, run:

```bash
./scripts/validate-acceptance-evidence.sh ./ACCEPTANCE-EVIDENCE.json
```

Prepare the fixed-bounty dry-run handoff only after validation:

```bash
./scripts/prepare-bounty-submission.sh \
  ./ACCEPTANCE-EVIDENCE.json ./barnacle-endpoint-bounty-submit-message.txt \
  https://your-public-writeup.example
```

The wrapper defaults to dry-run and cannot delegate a signed submission without
both `--submit` and the exact
`BARNACLE_BOUNTY_SUBMIT_ACK=mpmvuqlz8bfc9790ad94` acknowledgement.

## Deployment

- Production URL:
- Deployment timestamp UTC:
- Public GitHub repo or gist URL:
- Source archive URL:
- Source archive SHA-256:
- Source mirror commit:
- Source archive URL contains the exact source mirror commit:
- USDCx contract:
- Availability log:
- Availability commitment days:
- Earliest post-submission 14-day completion timestamp UTC:

## Non-Spending Preflight

Run:

```bash
./scripts/probe-public-v2.sh https://your-worker.example
```

- Preflight timestamp UTC:
- Health response:
- Three-token challenge:
- Forged relay rejection:
- Replay-identifier conflict:

## Authorized Mainnet Demonstrations

Record one confirmed production settlement for each advertised token. Preserve
the protected response payload and explorer URL. Do not record secrets or signed
transaction payloads.

After each separately authorized confirmed live demonstration, record its
artifact without signing, broadcasting, or spending from this helper:

```bash
./scripts/record-authorized-demo.sh \
  ./ACCEPTANCE-EVIDENCE.json STX 1 \
  <confirmed-txid> <https-explorer-url-containing-txid> \
  ./evidence/stx-paid-response.json <confirmed-utc>
```

| Token | Amount atomic units | Confirmed txid | Explorer URL | Protected response artifact | Confirmed UTC |
| --- | ---: | --- | --- | --- | --- |
| sBTC |  |  |  |  |  |
| STX |  |  |  |  |  |
| USDCx |  |  |  |  |  |

## Availability Window

Start the production-only monitor after deployment:

```bash
BARNACLE_PRODUCTION_LOG=./barnacle-production-liveness.log \
  ./scripts/start-production-monitor.sh https://your-worker.example 300
```

Audit the completed window before submission:

```bash
./scripts/summarize-production-availability.sh \
  ./barnacle-production-liveness.log 300 14
```

- Monitor start timestamp UTC:
- Monitor end timestamp UTC:
- Healthy row count:
- Missing or unhealthy intervals:
- Availability audit result:
- Initial healthy production row satisfied:
- Post-submission 14-day window satisfied:

## Submission Audit

- Stable production URL independently reachable:
- Source artifact anonymously readable:
- Three confirmed mainnet txids independently resolvable:
- Three protected paid responses preserved:
- 14-day availability commitment documented:
- No Quick Tunnel evidence represented as production:
