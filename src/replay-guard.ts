interface Reservation {
  fingerprint: string;
}

interface ReservationRequest {
  fingerprint: string;
  mode: 'idempotent' | 'unique';
}

export class ReplayGuard {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    if (request.method !== 'POST') {
      return Response.json({ error: 'method_not_allowed' }, { status: 405 });
    }

    const body = await request.json<ReservationRequest>();
    const existing = await this.state.storage.get<Reservation>('reservation');
    if (!existing) {
      await this.state.storage.put('reservation', { fingerprint: body.fingerprint });
      return Response.json({ reserved: true, duplicate: false });
    }

    if (body.mode === 'idempotent' && existing.fingerprint === body.fingerprint) {
      return Response.json({ reserved: true, duplicate: true });
    }

    return Response.json({ reserved: false, duplicate: true }, { status: 409 });
  }
}
