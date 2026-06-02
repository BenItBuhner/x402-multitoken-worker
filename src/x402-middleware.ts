import type { Context, Next } from 'hono';

export type TokenType = 'STX' | 'sBTC' | 'USDCx';

export interface X402Config {
  amount: string;
  tokenType: TokenType;
}

export interface X402MultiTokenConfig {
  amounts: Record<TokenType, string>;
}

interface PaymentRequirementsV2 {
  scheme: 'exact';
  network: `stacks:${string}`;
  amount: string;
  asset: string;
  payTo: string;
  maxTimeoutSeconds: number;
  extra: {
    tokenType: TokenType;
    relay: string;
  };
}

interface PaymentRequiredV2 {
  x402Version: 2;
  error?: string;
  resource: {
    url: string;
    description: string;
    mimeType: 'application/json';
  };
  accepts: PaymentRequirementsV2[];
}

interface PaymentPayloadV2 {
  x402Version: 2;
  resource?: PaymentRequiredV2['resource'];
  accepted: PaymentRequirementsV2;
  payload: {
    transaction: string;
  };
  extensions?: Record<string, unknown>;
}

export interface SettleResult {
  success: boolean;
  transaction?: string;
  network?: string;
  payer?: string;
  errorReason?: string;
  queue?: {
    status?: string;
  };
}

export interface X402Context {
  payerAddress: string;
  settleResult: SettleResult;
  paymentSignature: string;
  tokenType: TokenType;
}

type Env = {
  RECIPIENT_ADDRESS: string;
  NETWORK: string;
  RELAY_URL: string;
  REPLAY_GUARD: DurableObjectNamespace;
};

type PaymentErrorCode =
  | 'RELAY_UNAVAILABLE'
  | 'RELAY_ERROR'
  | 'PAYMENT_INVALID'
  | 'INSUFFICIENT_FUNDS'
  | 'PAYMENT_EXPIRED'
  | 'AMOUNT_TOO_LOW'
  | 'NETWORK_ERROR'
  | 'UNKNOWN_ERROR';

interface PaymentErrorResponse {
  error: string;
  code: PaymentErrorCode;
  retryAfter?: number;
  tokenType?: TokenType;
  resource: string;
  details?: Record<string, string | undefined>;
}

const TOKEN_CONTRACTS: Record<'mainnet' | 'testnet', Record<'sBTC' | 'USDCx', string>> = {
  mainnet: {
    sBTC: 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token',
    USDCx: 'SP120SBRBQJ00MCWS7TM5R8WJNTTKD5K0HFRC2CNE.usdcx',
  },
  testnet: {
    sBTC: 'ST1F7QA2MDF17S807EPA36TSS8AMEFY4KA9TVGWXT.sbtc-token',
    USDCx: 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.usdcx',
  },
};

const STACKS_NETWORKS: Record<'mainnet' | 'testnet', `stacks:${string}`> = {
  mainnet: 'stacks:1',
  testnet: 'stacks:2147483648',
};

function encodeBase64Json(value: unknown): string {
  return btoa(JSON.stringify(value));
}

function decodeBase64Json<T>(encoded: string): T | null {
  try {
    return JSON.parse(atob(encoded)) as T;
  } catch {
    return null;
  }
}

function getPaymentIdentifier(payload: PaymentPayloadV2): string | null {
  const extension = payload.extensions?.['payment-identifier'] as { info?: { id?: unknown } } | undefined;
  const id = String(extension?.info?.id || '');
  return /^[a-zA-Z0-9_-]{16,128}$/.test(id) ? id : null;
}

async function reserveReplayKey(
  namespace: DurableObjectNamespace,
  key: string,
  fingerprint: string,
  mode: 'idempotent' | 'unique',
): Promise<boolean> {
  const id = namespace.idFromName(key);
  const response = await namespace.get(id).fetch('https://replay-guard.internal/reserve', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ fingerprint, mode }),
  });
  return response.ok;
}

function classifyPaymentError(error: unknown, settleResult?: SettleResult): {
  code: PaymentErrorCode;
  message: string;
  httpStatus: number;
  retryAfter?: number;
} {
  const combined = `${String(error)} ${settleResult?.errorReason || ''}`.toLowerCase();

  if (combined.includes('503') || combined.includes('unavailable')) {
    return { code: 'RELAY_UNAVAILABLE', message: 'Payment relay temporarily unavailable', httpStatus: 503, retryAfter: 30 };
  }
  if (combined.includes('insufficient') || combined.includes('balance')) {
    return { code: 'INSUFFICIENT_FUNDS', message: 'Insufficient funds in wallet', httpStatus: 402 };
  }
  if (combined.includes('expired') || combined.includes('nonce')) {
    return { code: 'PAYMENT_EXPIRED', message: 'Payment expired, please sign a new payment', httpStatus: 402 };
  }
  if (combined.includes('amount') && (combined.includes('low') || combined.includes('minimum'))) {
    return { code: 'AMOUNT_TOO_LOW', message: 'Payment amount below minimum required', httpStatus: 402 };
  }
  if (combined.includes('invalid') || combined.includes('signature') || combined.includes('payload')) {
    return { code: 'PAYMENT_INVALID', message: 'Invalid payment signature', httpStatus: 400 };
  }
  if (combined.includes('fetch') || combined.includes('network') || combined.includes('timeout')) {
    return { code: 'NETWORK_ERROR', message: 'Network error with payment relay', httpStatus: 502, retryAfter: 5 };
  }
  return { code: 'UNKNOWN_ERROR', message: 'Payment processing error', httpStatus: 500, retryAfter: 5 };
}

function assetFor(tokenType: TokenType, network: 'mainnet' | 'testnet'): string {
  return tokenType === 'STX' ? 'STX' : TOKEN_CONTRACTS[network][tokenType];
}

function buildRequirement(
  config: X402Config,
  network: 'mainnet' | 'testnet',
  recipientAddress: string,
  relayUrl: string,
): PaymentRequirementsV2 {
  return {
    scheme: 'exact',
    network: STACKS_NETWORKS[network],
    amount: config.amount,
    asset: assetFor(config.tokenType, network),
    payTo: recipientAddress,
    maxTimeoutSeconds: 300,
    extra: {
      tokenType: config.tokenType,
      relay: relayUrl,
    },
  };
}

function stripRelayMetadata(requirement: PaymentRequirementsV2): Omit<PaymentRequirementsV2, 'extra'> {
  const { extra: _extra, ...settlementRequirement } = requirement;
  return settlementRequirement;
}

function challenge(
  c: Context<{ Bindings: Env; Variables: { x402?: X402Context } }>,
  requirements: PaymentRequirementsV2[],
  error = 'payment_required',
) {
  const required: PaymentRequiredV2 = {
    x402Version: 2,
    error,
    resource: {
      url: c.req.url,
      description: 'Compact JSON metadata',
      mimeType: 'application/json',
    },
    accepts: requirements,
  };

  c.header('payment-required', encodeBase64Json(required));
  return c.json({
    error,
    x402: required,
    ...required,
  }, 402);
}

function paymentMiddleware(configs: X402Config[]) {
  return async (c: Context<{ Bindings: Env; Variables: { x402?: X402Context } }>, next: Next) => {
    const network = (c.env.NETWORK || 'testnet') as 'mainnet' | 'testnet';
    const relayUrl = c.env.RELAY_URL || (network === 'mainnet' ? 'https://x402-relay.aibtc.com' : 'https://x402-relay.aibtc.dev');
    const requirements = configs.map(config => buildRequirement(config, network, c.env.RECIPIENT_ADDRESS, relayUrl));
    const paymentSignature = c.req.header('payment-signature') || c.req.header('X-PAYMENT');

    if (!paymentSignature) {
      return challenge(c, requirements);
    }

    const paymentPayload = decodeBase64Json<PaymentPayloadV2>(paymentSignature);
    if (!paymentPayload || paymentPayload.x402Version !== 2 || !paymentPayload.payload?.transaction) {
      return c.json({
        error: 'Invalid payment signature',
        code: 'PAYMENT_INVALID',
        resource: c.req.path,
      } satisfies PaymentErrorResponse, 400);
    }

    const paymentIdentifier = getPaymentIdentifier(paymentPayload);
    if (!paymentIdentifier) {
      return c.json({
        error: 'Missing or invalid payment-identifier extension',
        code: 'PAYMENT_INVALID',
        resource: c.req.path,
      } satisfies PaymentErrorResponse, 400);
    }

    const selectedRequirement = requirements.find(requirement =>
      requirement.asset === paymentPayload.accepted?.asset
      && requirement.amount === paymentPayload.accepted?.amount
      && requirement.network === paymentPayload.accepted?.network
      && requirement.payTo === paymentPayload.accepted?.payTo
    );

    if (!selectedRequirement) {
      return c.json({
        error: 'Payment signature selected an unsupported requirement',
        code: 'PAYMENT_INVALID',
        resource: c.req.path,
      } satisfies PaymentErrorResponse, 400);
    }

    const fingerprint = encodeBase64Json(paymentPayload);
    if (!await reserveReplayKey(c.env.REPLAY_GUARD, `payment-id:${paymentIdentifier}`, fingerprint, 'idempotent')) {
      return c.json({
        error: 'Payment identifier was already used with a different payload',
        code: 'PAYMENT_INVALID',
        resource: c.req.path,
      } satisfies PaymentErrorResponse, 409);
    }

    let settleResult: SettleResult;
    try {
      const relayResponse = await fetch(`${relayUrl}/settle`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          x402Version: 2,
          paymentPayload: {
            ...paymentPayload,
            accepted: selectedRequirement,
          },
          paymentRequirements: stripRelayMetadata(selectedRequirement),
        }),
      });
      const responseBody = await relayResponse.json().catch(() => ({})) as SettleResult;
      if (!relayResponse.ok) {
        throw new Error(`Relay returned ${relayResponse.status}: ${JSON.stringify(responseBody)}`);
      }
      settleResult = responseBody;
    } catch (error) {
      const classified = classifyPaymentError(error);
      if (classified.retryAfter) c.header('Retry-After', String(classified.retryAfter));
      return c.json({
        error: classified.message,
        code: classified.code,
        retryAfter: classified.retryAfter,
        tokenType: selectedRequirement.extra.tokenType,
        resource: c.req.path,
        details: { exceptionMessage: String(error) },
      } satisfies PaymentErrorResponse, classified.httpStatus as 400 | 402 | 500 | 502 | 503);
    }

    if (!settleResult.success) {
      const classified = classifyPaymentError(settleResult.errorReason || 'invalid', settleResult);
      if (classified.retryAfter) c.header('Retry-After', String(classified.retryAfter));
      return c.json({
        error: classified.message,
        code: classified.code,
        retryAfter: classified.retryAfter,
        tokenType: selectedRequirement.extra.tokenType,
        resource: c.req.path,
        details: { settleReason: settleResult.errorReason },
      } satisfies PaymentErrorResponse, classified.httpStatus as 400 | 402 | 500 | 502 | 503);
    }

    if (!settleResult.transaction || !await reserveReplayKey(
      c.env.REPLAY_GUARD,
      `txid:${settleResult.transaction.toLowerCase()}`,
      fingerprint,
      'unique',
    )) {
      return c.json({
        error: 'Settled transaction replay detected',
        code: 'PAYMENT_INVALID',
        resource: c.req.path,
      } satisfies PaymentErrorResponse, 409);
    }

    const payerAddress = settleResult.payer || 'unknown';
    c.set('x402', {
      payerAddress,
      settleResult,
      paymentSignature,
      tokenType: selectedRequirement.extra.tokenType,
    });
    c.header('payment-response', encodeBase64Json(settleResult));
    c.header('X-PAYER-ADDRESS', payerAddress);
    await next();
  };
}

export function x402Middleware(config: X402Config) {
  return paymentMiddleware([config]);
}

export function x402MultiTokenMiddleware(config: X402MultiTokenConfig) {
  return paymentMiddleware(
    (Object.entries(config.amounts) as [TokenType, string][])
      .map(([tokenType, amount]) => ({ tokenType, amount })),
  );
}
