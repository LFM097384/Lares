// hearthvoice-lares · 把 lares-bridge 的 LaresRoom 适配成灶语的 port(../hearthvoice/PORT.md)。
// 事件名映射:LaresRoom 'names' → port 'name';其余同名。出站音轨 = LaresRoom 进房时发布的 'ai-voice' 轨。

import { isLaresHuman } from '../lares-bridge/index.mjs';

const EVENT_MAP = Object.freeze({ audio: 'audio', chat: 'chat', name: 'names', joined: 'joined', left: 'left', capctl: 'capctl', disconnected: 'disconnected' });

/**
 * @param {import('../lares-bridge/index.mjs').LaresRoom} room  未进房的 LaresRoom(或同形的假房间)
 */
export function laresVoicePort(room) {
  return {
    get selfId() { return room.userId; },
    isHuman: isLaresHuman, // u_ai_*(别的 AI)/ bot:* 不听不答
    on(ev, fn) {
      const k = EVENT_MAP[ev];
      if (!k) throw new Error(`unknown port event ${ev}`);
      room.on(k, fn);
    },
    join: () => room.join(),
    leave: () => room.leave(),
    audioOut: () => room.sink(),
    sendChat: (t) => room.sendChat(t),
    publishCaption: (c) => room.publishCaption(c),
    publishState: (f) => room.publishState(f),
    rename: (n) => room.rename(n),
  };
}
