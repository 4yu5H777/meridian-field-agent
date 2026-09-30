// WhatsApp delivery for outbox messages. Channels.send needs a WhatsApp channel
// of the agent's own; on Lua's shared test number there is none, and the way
// back to a person is user.send() on the Lua user they wrote in as (recorded by
// the identity gate in lua_user_links). So: Channels.send first, then
// user.send() when we know the recipient's Lua user. Pure (sends injected).
export type WhatsAppDeps = {
  channelsSend: (phone: string, text: string) => Promise<{ deliveryId?: string } | undefined>;
  userSend: (luaUserId: string, text: string) => Promise<boolean>;   // false: no such Lua user
};

export async function deliverWhatsApp(m: { address: string; text: string; luaUserId?: string }, d: WhatsAppDeps): Promise<{ ref: string }> {
  try {
    const r = await d.channelsSend(m.address, m.text);
    return { ref: String(r?.deliveryId ?? '') };
  } catch (first) {
    if (!m.luaUserId) throw first;
    if (!(await d.userSend(m.luaUserId, m.text))) throw new Error('recipient has no Lua user');
    // user.send() resolves true whatever happened once deployed; the ref says which path was used.
    return { ref: 'user.send' };
  }
}
