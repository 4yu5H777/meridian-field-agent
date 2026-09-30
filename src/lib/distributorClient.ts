import { DistributorError } from './submit.ts';

// POST one order to the distributor. The idempotency key is the order's
// MER-ORDER-<id>: a resend after a timeout gets the same distributor_ref.
// Never includes the API key or URL in an error.
export function distributorSender(baseUrl: string, apiKey: string) {
  return async (payload: unknown, idempotencyKey: string): Promise<{ distributor_ref: string }> => {
    let res: Response;
    try {
      res = await fetch(`${baseUrl.replace(/\/+$/, '')}/orders`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${apiKey}`, 'x-idempotency-key': idempotencyKey },
        body: JSON.stringify(payload),
      });
    } catch {
      throw new DistributorError('unreachable');
    }
    if (res.status !== 200 && res.status !== 201) throw new DistributorError(`HTTP ${res.status}`);
    let body: unknown;
    try { body = await res.json(); } catch { throw new DistributorError('response is not JSON'); }
    return { distributor_ref: String((body as { distributor_ref?: unknown })?.distributor_ref ?? '') };
  };
}
