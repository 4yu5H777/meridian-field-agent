// Unit tests: WhatsApp delivery falls back to user.send on Lua's test number.
//   node --test tests/whatsappDelivery.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deliverWhatsApp } from '../src/lib/whatsappDelivery.ts';

const msg = { address: '+919800000000', text: 'Order #81: credit approved', luaUserId: 'user_abc' };

test('own WhatsApp channel: Channels.send, and user.send is not used', async () => {
  const used: string[] = [];
  const r = await deliverWhatsApp(msg, { channelsSend: async () => { used.push('channels'); return { deliveryId: 'd1' }; }, userSend: async () => { used.push('user'); return true; } });
  assert.deepEqual([r, used], [{ ref: 'd1' }, ['channels']]);
});

test('test number (no channel of ours): falls back to the Lua user the person wrote in as', async () => {
  const sent: string[][] = [];
  const r = await deliverWhatsApp(msg, {
    channelsSend: async () => { throw new Error('No WhatsApp channel configuration found'); },
    userSend: async (id, text) => { sent.push([id, text]); return true; } });
  assert.deepEqual([r, sent], [{ ref: 'user.send' }, [['user_abc', 'Order #81: credit approved']]]);
});

test('no known Lua user, or the user is gone: the error is thrown so the outbox retries', async () => {
  const fail = async () => { throw new Error('No WhatsApp channel configuration found'); };
  await assert.rejects(deliverWhatsApp({ ...msg, luaUserId: undefined }, { channelsSend: fail, userSend: async () => true }), /No WhatsApp channel/);
  await assert.rejects(deliverWhatsApp(msg, { channelsSend: fail, userSend: async () => false }), /no Lua user/);
});
