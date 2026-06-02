// BigInt.toJSON polyfill for JSON.stringify compatibility
(BigInt.prototype as unknown as { toJSON: () => string }).toJSON = function () {
  return this.toString();
};

import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { x402Middleware, x402MultiTokenMiddleware } from './x402-middleware';
import type { X402Context } from './x402-middleware';
export { ReplayGuard } from './replay-guard';

type Env = {
  RECIPIENT_ADDRESS: string;
  NETWORK: string;
  RELAY_URL: string;
  REPLAY_GUARD: DurableObjectNamespace;
};

type Variables = {
  x402?: X402Context;
};

const app = new Hono<{ Bindings: Env; Variables: Variables }>();

// CORS middleware with x402 headers
app.use('*', cors({
  origin: '*',
  allowMethods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
  allowHeaders: ['payment-signature', 'X-PAYMENT', 'Authorization', 'Content-Type'],
  exposeHeaders: ['payment-required', 'payment-response', 'X-PAYER-ADDRESS'],
}));

// Startup validation - fail fast if required secrets are missing
app.use('*', async (c, next) => {
  // Skip validation for health check
  if (c.req.path === '/health') {
    return next();
  }

  const missingSecrets: string[] = [];

  if (!c.env.RECIPIENT_ADDRESS) {
    missingSecrets.push('RECIPIENT_ADDRESS');
  }

  if (missingSecrets.length > 0) {
    return c.json({
      error: 'Server configuration error',
      message: `Missing required secrets: ${missingSecrets.join(', ')}`,
      hint: missingSecrets.map(s => `Run: wrangler secret put ${s}`).join(' && '),
    }, 503);
  }

  await next();
});

// Service info at root (free)
app.get('/', (c) => {
  return c.json({
    service: 'x402-api',
    version: '1.0.0',
    health: '/health',
    payment: {
      tokens: ['sBTC', 'STX', 'USDCx'],
      challengeHeader: 'payment-required',
      signatureHeader: 'payment-signature',
      responseHeader: 'payment-response',
    },
  });
});

// Health check (free)
app.get('/health', (c) => {
  return c.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    network: c.env.NETWORK || 'testnet',
  });
});

// Return deterministic JSON request metadata for paid callers
app.post('/api/compact',
  x402Middleware({
    amount: '10',
    tokenType: 'sBTC',
  }),
  async (c) => {
    const payment = c.get('x402');

    // Parse request body
    const body = await c.req.json<Record<string, unknown>>().catch(() => ({}));

    // Your business logic here - this example echoes the request
    const result = {
      received: body,
      processedAt: new Date().toISOString(),
    };

    return c.json({
      success: true,
      data: result,
      payment: {
        txId: payment?.settleResult?.transaction,
        sender: payment?.payerAddress,
        tokenType: payment?.tokenType,
      },
    });
  }
);

app.post('/api/multi-compact',
  x402MultiTokenMiddleware({
    amounts: {
      sBTC: '10',
      STX: '1',
      USDCx: '1',
    },
  }),
  async (c) => {
    const payment = c.get('x402');
    const body = await c.req.json<Record<string, unknown>>().catch(() => ({}));

    return c.json({
      success: true,
      data: {
        received: body,
        processedAt: new Date().toISOString(),
      },
      payment: {
        txId: payment?.settleResult?.transaction,
        sender: payment?.payerAddress,
        tokenType: payment?.tokenType,
      },
    });
  }
);

export default app;
