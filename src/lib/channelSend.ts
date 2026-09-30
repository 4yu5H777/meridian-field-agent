import { Channels, User } from 'lua-cli';
import type { OutgoingMessage } from './notify.ts';
import { deliverWhatsApp } from './whatsappDelivery.ts';

// Delivers one outbox message on its channel. Returns the provider's reference
// (the email Message-ID, or the delivery id) for the outbox row.
export async function sendOutgoing(m: OutgoingMessage): Promise<{ ref: string }> {
  if (m.channel === 'email') {
    const r = await Channels.email.send({ to: { email: m.address }, subject: m.subject, text: m.text }) as { messageId?: string; deliveryId?: string };
    return { ref: String(r?.messageId ?? r?.deliveryId ?? '') };
  }
  return deliverWhatsApp(m, {
    channelsSend: async (phone, text) => await Channels.send({ channel: 'whatsapp', to: { phoneNumber: phone }, text }) as { deliveryId?: string },
    userSend: async (luaUserId, text) => {
      const user = await User.get(luaUserId);
      if (!user) return false;
      await user.send([{ type: 'text', text }]);
      return true;
    },
  });
}
