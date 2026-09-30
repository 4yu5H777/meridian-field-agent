// Reviewer registration (the brief's "a documented way to register our own
// numbers and emails"). One command:
//
//   curl -X POST https://webhook.heylua.ai/<agentId>/reviewer-registration \
//     -H 'Content-Type: application/json' -H 'x-registration-key: <key>' \
//     -d '{"role":"rep","phone":"+91 98xxxxxxxx","email":"you@example.com"}'
//
// role: rep | manager | regional_head. {"remove": true, "phone": ...} takes a
// contact off again. The database (register_demo_contact, system role) only
// ever attaches contacts to the three demo people and never moves anyone
// else's. This file checks the key and the shape; pure, so it is unit-tested.
import { header } from './callback.ts';

export type Register = (role: string | null, channel: 'whatsapp' | 'email', value: string, remove: boolean) => Promise<unknown>;
export type RegistrationResponse =
  | { ok: false; error: string }
  | { ok: boolean; results: { channel: string; ok: boolean; status?: string; error?: string; as?: string }[] };

export const MIN_KEY_LENGTH = 24;
const ROLES = ['rep', 'manager', 'regional_head'];

async function digest(s: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
}

// Compare fixed-length digests, so neither the key's length nor a matching
// prefix shows in the timing.
export async function keyMatches(expected: string, given: unknown): Promise<boolean> {
  if (typeof given !== 'string' || given.length === 0 || given.length > 256) return false;
  const [a, b] = await Promise.all([digest(expected), digest(given)]);
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

const str = (v: unknown, max: number) => (typeof v === 'string' && v.trim() !== '' && v.length <= max ? v.trim() : null);

export async function handleRegistration(input: {
  headers: unknown; body: unknown; key: string | undefined; register: Register; timeoutMs: number;
}): Promise<RegistrationResponse> {
  if (!input.key || input.key.length < MIN_KEY_LENGTH) return { ok: false, error: 'not configured' };
  if (!(await keyMatches(input.key, header(input.headers, 'x-registration-key')))) return { ok: false, error: 'unauthorized' };

  let body = input.body;
  if (typeof body === 'string') {
    try { body = JSON.parse(body); } catch { return { ok: false, error: 'invalid body' }; }
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { ok: false, error: 'invalid body' };
  const b = body as Record<string, unknown>;
  const remove = b.remove === true;
  const role = remove ? null : str(b.role, 20);
  if (!remove && (!role || !ROLES.includes(role))) return { ok: false, error: 'role must be rep, manager or regional_head' };
  const contacts: ['whatsapp' | 'email', string][] = [];
  const phone = str(b.phone, 40);
  const email = str(b.email, 320);
  if (phone) contacts.push(['whatsapp', phone]);
  if (email) contacts.push(['email', email]);
  if (contacts.length === 0) return { ok: false, error: 'give a phone (WhatsApp, with country code) and/or an email' };

  const results: { channel: string; ok: boolean; status?: string; error?: string; as?: string }[] = [];
  for (const [channel, value] of contacts) {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const r = await Promise.race([
        input.register(role, channel, value, remove),
        new Promise<never>((_, rej) => { timer = setTimeout(() => rej(new Error('timeout')), input.timeoutMs); }),
      ]) as Record<string, unknown> | null;
      if (r?.ok === true) {
        results.push({ channel, ok: true, status: String(r.status ?? ''), ...(typeof r.as === 'string' ? { as: r.as } : {}) });
      } else {
        const known = ['taken', 'bad_contact', 'bad_role', 'bad_channel', 'not_registered', 'limit_reached', 'not_available'];
        results.push({ channel, ok: false, error: known.includes(String(r?.error)) ? String(r?.error) : 'failed' });
      }
    } catch {
      results.push({ channel, ok: false, error: 'failed' });              // never a driver error text
    } finally {
      clearTimeout(timer);
    }
  }
  return { ok: results.every((r) => r.ok), results };
}
