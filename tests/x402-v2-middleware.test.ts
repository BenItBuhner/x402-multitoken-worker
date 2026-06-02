import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import app from '../src/index';

const replayEntries = new Map<string, string>();
const replayGuard = {
  idFromName(name: string) {
    return name;
  },
  get(id: string) {
    return {
      async fetch(_url: string, init: RequestInit) {
        const body = JSON.parse(String(init.body)) as {
          fingerprint: string;
          mode: 'idempotent' | 'unique';
        };
        const existing = replayEntries.get(id);
        if (!existing) {
          replayEntries.set(id, body.fingerprint);
          return Response.json({ reserved: true, duplicate: false });
        }
        if (body.mode === 'idempotent' && existing === body.fingerprint) {
          return Response.json({ reserved: true, duplicate: true });
        }
        return Response.json({ reserved: false, duplicate: true }, { status: 409 });
      },
    };
  },
} as unknown as DurableObjectNamespace;

const env = {
  RECIPIENT_ADDRESS: 'STRECIPIENT',
  NETWORK: 'testnet',
  RELAY_URL: 'https://relay.example',
  REPLAY_GUARD: replayGuard,
};

const sbtc = {
  scheme: 'exact',
  network: 'stacks:2147483648',
  amount: '10',
  asset: 'ST1F7QA2MDF17S807EPA36TSS8AMEFY4KA9TVGWXT.sbtc-token',
  payTo: env.RECIPIENT_ADDRESS,
  maxTimeoutSeconds: 300,
  extra: {
    tokenType: 'sBTC',
    relay: env.RELAY_URL,
  },
};

function request(path: string, init: RequestInit = {}) {
  return app.request(`https://worker.example${path}`, init, env);
}

function encode(value: unknown) {
  return Buffer.from(JSON.stringify(value)).toString('base64');
}

function decode<T>(value: string | null): T {
  expect(value).toBeTruthy();
  return JSON.parse(Buffer.from(value!, 'base64').toString('utf8')) as T;
}

function paymentSignature(accepted = sbtc) {
  return encode({
    x402Version: 2,
    accepted,
    payload: { transaction: '0xsigned' },
    extensions: {
      'payment-identifier': {
        info: { id: 'pay_fixture_00000000' },
      },
    },
  });
}

describe('x402 v2 middleware', () => {
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    replayEntries.clear();
    fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('returns a base64 v2 challenge for the unpaid single-token route', async () => {
    const response = await request('/api/compact', { method: 'POST' });
    const body = await response.json() as Record<string, unknown>;
    const header = decode<Record<string, unknown>>(response.headers.get('payment-required'));

    expect(response.status).toBe(402);
    expect(header.x402Version).toBe(2);
    expect(header).toEqual(body.x402);
    expect((header.accepts as unknown[])).toHaveLength(1);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('advertises three server-owned v2 options for the unpaid multi-token route', async () => {
    const response = await request('/api/multi-compact', { method: 'POST' });
    const header = decode<{ accepts: Array<{ extra: { tokenType: string } }> }>(
      response.headers.get('payment-required'),
    );

    expect(response.status).toBe(402);
    expect(header.accepts.map(option => option.extra.tokenType)).toEqual(['sBTC', 'STX', 'USDCx']);
  });

  it('settles a supported signature and emits a base64 payment response', async () => {
    fetchMock.mockResolvedValue(new Response(JSON.stringify({
      success: true,
      payer: 'STPAYER',
      transaction: '0xtxid',
      network: 'stacks:2147483648',
    }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    }));

    const response = await request('/api/compact', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'payment-signature': paymentSignature(),
      },
      body: JSON.stringify({ value: 42 }),
    });
    const body = await response.json() as Record<string, unknown>;
    const settlement = decode<Record<string, unknown>>(response.headers.get('payment-response'));
    const relayBody = JSON.parse(fetchMock.mock.calls[0][1].body as string);

    expect(response.status).toBe(200);
    expect(body.success).toBe(true);
    expect(settlement.transaction).toBe('0xtxid');
    expect(relayBody.x402Version).toBe(2);
    expect(relayBody.paymentPayload.accepted).toEqual(sbtc);
    expect(relayBody.paymentRequirements).toEqual({
      scheme: 'exact',
      network: 'stacks:2147483648',
      amount: '10',
      asset: sbtc.asset,
      payTo: env.RECIPIENT_ADDRESS,
      maxTimeoutSeconds: 300,
    });
  });

  it.each([
    ['malformed base64', 'not-json'],
    ['wrong protocol version', encode({ x402Version: 1, payload: { transaction: '0xsigned' } })],
  ])('rejects %s before contacting the relay', async (_label, signature) => {
    const response = await request('/api/compact', {
      method: 'POST',
      headers: { 'payment-signature': signature },
    });

    expect(response.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('rejects a client-selected requirement that the server did not offer', async () => {
    const response = await request('/api/compact', {
      method: 'POST',
      headers: {
        'payment-signature': paymentSignature({ ...sbtc, amount: '1' }),
      },
    });

    expect(response.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('rejects reuse of a settled transaction id', async () => {
    fetchMock.mockImplementation(async () => new Response(JSON.stringify({
        success: true,
        payer: 'STPAYER',
        transaction: '0xreplayed',
        network: 'stacks:2147483648',
      }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }));

    const first = await request('/api/compact', {
      method: 'POST',
      headers: { 'payment-signature': paymentSignature() },
    });
    const second = await request('/api/compact', {
      method: 'POST',
      headers: {
        'payment-signature': encode({
          x402Version: 2,
          accepted: sbtc,
          payload: { transaction: '0xother-signed-tx' },
          extensions: {
            'payment-identifier': {
              info: { id: 'pay_distinct_fixture' },
            },
          },
        }),
      },
    });
    const secondBody = await second.clone().json();

    expect(first.status).toBe(200);
    expect(second.status, JSON.stringify(secondBody)).toBe(409);
  });

  it.each([
    ['invalid_payload', 400, 'PAYMENT_INVALID'],
    ['nonce expired', 402, 'PAYMENT_EXPIRED'],
    ['amount below minimum', 402, 'AMOUNT_TOO_LOW'],
  ])('classifies relay rejection %s', async (errorReason, expectedStatus, expectedCode) => {
    fetchMock.mockResolvedValue(new Response(JSON.stringify({
      success: false,
      errorReason,
    }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    }));

    const response = await request('/api/compact', {
      method: 'POST',
      headers: { 'payment-signature': paymentSignature() },
    });
    const body = await response.json() as Record<string, unknown>;

    expect(response.status).toBe(expectedStatus);
    expect(body.code).toBe(expectedCode);
  });

  it('classifies a relay timeout and advertises a bounded retry', async () => {
    fetchMock.mockRejectedValue(new Error('fetch timeout'));

    const response = await request('/api/compact', {
      method: 'POST',
      headers: { 'payment-signature': paymentSignature() },
    });
    const body = await response.json() as Record<string, unknown>;

    expect(response.status).toBe(502);
    expect(response.headers.get('Retry-After')).toBe('5');
    expect(body.code).toBe('NETWORK_ERROR');
  });

  it('allows and exposes the v2 headers during CORS preflight', async () => {
    const response = await request('/api/compact', {
      method: 'OPTIONS',
      headers: {
        Origin: 'https://client.example',
        'Access-Control-Request-Method': 'POST',
        'Access-Control-Request-Headers': 'payment-signature',
      },
    });

    expect(response.status).toBe(204);
    expect(response.headers.get('Access-Control-Allow-Headers')).toContain('payment-signature');
    expect(response.headers.get('Access-Control-Expose-Headers')).toContain('payment-required');
    expect(response.headers.get('Access-Control-Expose-Headers')).toContain('payment-response');
  });
});
