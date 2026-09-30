// Who is talking, as far as the platform (not the model) says. Pure, so it can
// be unit-tested with plain Node. Used by the prepare_order tool and the
// summary-integrity postprocessor; the confirmation gate keeps its own copy of
// these rules (src/lib/confirmation.ts `decide`) and is deliberately unchanged.
//
// The result is only the channel and the contacts to hand to the database.
// Whether those contacts belong to exactly one active rep is decided by
// meridian.identify_sender / prepare_order / live_order_summaries, never here.
import { contactsFor, type ConfirmChannel, type InvokedState, type LuaProfile } from './confirmation.ts';

export type SenderContext =
  | { ok: true; channel: ConfirmChannel; contacts: string[] }
  | { ok: false; reason: 'wrong_channel' | 'invoked' | 'channel_mismatch' | 'no_contacts' };

// channel         the channel this code was handed (postprocessor argument, or
//                 Lua.request.channel for a tool)
// requestChannel  Lua.request.channel (undefined when unavailable)
// invoked         whether Lua.request says the turn was started by code
export function senderContext(input: {
  channel: string | undefined;
  requestChannel: string | undefined;
  invoked: InvokedState;
  profile: LuaProfile | null | undefined;
}): SenderContext {
  if (input.invoked !== 'no') return { ok: false, reason: 'invoked' };
  if (input.channel !== 'whatsapp' && input.channel !== 'email') return { ok: false, reason: 'wrong_channel' };
  if (input.requestChannel !== input.channel) return { ok: false, reason: 'channel_mismatch' };
  const contacts = contactsFor(input.channel, input.profile);
  if (contacts.length === 0) return { ok: false, reason: 'no_contacts' };
  return { ok: true, channel: input.channel, contacts };
}
