// Rule "Identity": who is this, before anything reasons about it. Pure, so it
// can be unit-tested; the database call is passed in.
//
// Every inbound turn is screened here first. Only a sender whose platform-
// verified contacts (user._luaProfile) resolve to exactly one active rep,
// area manager or regional head proceeds. Everyone else is blocked with a
// fixed reply that carries nothing from Meridian's data, and the model never
// sees their message. Every failure path blocks: the platform SKIPS a
// preprocessor that throws on text channels, so this code must never throw
// and must never let an unscreened turn through.
//
// This gate is the front door, not the only lock: every tool and database
// function still resolves the sender itself and scopes what it returns.
import { senderContext } from './identity.ts';
import { GateTimeout, describeError, type ConfirmChannel, type InvokedState, type LuaProfile } from './confirmation.ts';

export type ScreenResult = { result?: unknown; role?: unknown } | null | undefined;
export type IdentityOutcome =
  | { action: 'proceed'; log: string }
  | { action: 'block'; response: string; log: string };

export const ROLES = ['rep', 'area_manager', 'regional_head'] as const;

// Fixed replies. The unknown-sender one is the same whether the contact is
// unknown, retired, deactivated or ambiguous, so it confirms nothing.
export const REPLY_UNREGISTERED =
  'Sorry, this assistant is only for registered Meridian Healthcare staff. '
  + 'If you work for Meridian, ask your area manager to register this number or email address.';
export const REPLY_WRONG_CHANNEL = 'Sorry, this assistant is only available on Meridian Healthcare\'s WhatsApp number and email.';
export const REPLY_UNAVAILABLE = 'Sorry, I cannot take messages right now. Please try again in a few minutes.';

export async function screenTurn(input: {
  channel: string | undefined;
  requestChannel: string | undefined;
  invoked: InvokedState;
  profile: LuaProfile | null | undefined;
  screen: (channel: ConfirmChannel, contacts: string[]) => Promise<ScreenResult>;
  timeoutMs: number;
}): Promise<IdentityOutcome> {
  const sender = senderContext(input);
  if (!sender.ok) {
    switch (sender.reason) {
      case 'wrong_channel': return { action: 'block', response: REPLY_WRONG_CHANNEL, log: 'blocked (wrong_channel)' };
      case 'no_contacts': return { action: 'block', response: REPLY_UNREGISTERED, log: 'blocked (no_contacts)' };
      default: return { action: 'block', response: REPLY_UNAVAILABLE, log: `blocked (${sender.reason})` };
    }
  }

  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new GateTimeout()), input.timeoutMs);
  });
  try {
    const r = await Promise.race([input.screen(sender.channel, sender.contacts), timeout]);
    const result = typeof r?.result === 'string' ? r.result : '';
    if (result === 'ok' && ROLES.includes(r?.role as typeof ROLES[number])) {
      return { action: 'proceed', log: `ok (${r?.role})` };
    }
    if (result === 'unknown_sender' || result === 'ambiguous_sender') {
      return { action: 'block', response: REPLY_UNREGISTERED, log: `blocked (${result})` };
    }
    // 'ok' without a known role, bad_channel, or anything unexpected.
    return { action: 'block', response: REPLY_UNAVAILABLE, log: 'blocked (unexpected result)' };
  } catch (err) {
    return { action: 'block', response: REPLY_UNAVAILABLE, log: `blocked (database call failed: ${describeError(err)})` };
  } finally {
    clearTimeout(timer);
  }
}
