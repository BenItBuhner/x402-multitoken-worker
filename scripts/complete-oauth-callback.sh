#!/usr/bin/env bash
set -euo pipefail

callback_url=${1:?usage: complete-oauth-callback.sh <localhost-wrangler-callback-url>}

node - "$callback_url" <<'NODE'
try {
  const url = new URL(process.argv[2]);
  if (url.protocol !== 'http:') throw new Error('callback must use http');
  if (url.hostname !== 'localhost' && url.hostname !== '127.0.0.1') {
    throw new Error('callback must target localhost');
  }
  if (url.port !== '8976') throw new Error('callback must target port 8976');
  if (url.pathname !== '/oauth/callback') throw new Error('unexpected callback path');
  if (!url.searchParams.has('code') || !url.searchParams.has('state')) {
    throw new Error('callback must include code and state');
  }
} catch (error) {
  console.error(`refusing invalid Wrangler callback URL: ${error.message}`);
  process.exit(2);
}
NODE

curl --max-time 20 -fsS "$callback_url" >/dev/null
printf 'wrangler_oauth_callback_completed\n'
