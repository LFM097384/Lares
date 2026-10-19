// ember-lares · 把 Lares 房间(AnonRoom,或测试用的 FakeRoom)包成 Ember 的平台 port(../ember/PORT.md)。
// 这里是 Ember 中立事件 ↔ Lares 线协议的唯一映射处:
//   port.send(obj, to)                 → LiveKit data topic `lares.anon`(reliable;to = destination_identities)
//   房间 'anon'(id, msg)               → port 'message'(id, msg)
//   房间 'names'(id, name)             → port 'name'(id, name)
//   notifyHost({type:'active', on})    → 信令 {t:'anon_active', circleId, on}
//   notifyHost({type:'released', ids}) → 信令 {t:'anon_released_notice', circleId, itemIds}
// 线协议名(anon_*、lares.anon、u_ai_anon_*)一律不改,app 与服务器保持兼容。

const EVENT_MAP = Object.freeze({ name: 'names', message: 'anon', joined: 'joined', left: 'left', audio: 'audio', disconnected: 'disconnected' });

/// Lares 规则:u_ai_*(语音助手 / 隐名 agent)与 bot:*(bot API 身份)不是真人
export { isLaresHuman } from '../lares-bridge/index.mjs';
import { isLaresHuman } from '../lares-bridge/index.mjs';

export function laresPort(room, { circleId, selfId = room.userId } = {}) {
  if (!circleId) throw new TypeError('laresPort: circleId required');
  return {
    selfId,
    isHuman: isLaresHuman,
    on(ev, fn) {
      const k = EVENT_MAP[ev];
      if (!k) throw new TypeError(`laresPort: unknown event ${ev}`);
      if (ev === 'joined') return room.on('joined', (id) => fn(id, room.nameOf?.(id) ?? ''));
      return room.on(k, fn);
    },
    participants: () => room.participants?.() ?? [],
    nameOf: (id) => room.nameOf?.(id) ?? '',
    send: (obj, to = null) => room.publishAnon(obj, to),
    notifyHost(ev) {
      if (ev?.type === 'active') return room.notifyServer({ t: 'anon_active', circleId, on: ev.on === true });
      if (ev?.type === 'released' && Array.isArray(ev.itemIds)) return room.notifyServer({ t: 'anon_released_notice', circleId, itemIds: ev.itemIds });
      return undefined;
    },
    join: () => room.join(),
    leave: () => room.leave(),
  };
}
