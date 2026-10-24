// ember-zoom · 把一条 RTMS 流 + 侧边栏 hub 包成 Ember 的平台 port(../ember/PORT.md)。
// 这里是 Ember 中立事件 ↔ Zoom 线协议的唯一映射处(同 ember-lares/port.mjs 的角色):
//   RTMS PARTICIPANT_JOIN / LEAVE (msg 6, event 3/4)  → port 'joined'(id, name) / 'left'(id)
//   RTMS 转写 (msg 17)                                  → port 'transcript'(id, text)   (port.transcripts = true;Ember 照样只收已 ack 的人)
//   RTMS 音频 (msg 14,可选,每人 L16 16 kHz)           → port 'audio'(id, pcm, 16000, 1)
//   侧边栏 hub 收到的协议 JSON                          → port 'message'(id, obj)
//   port.send(obj, to)                                  → 侧边栏 hub(只发给本场会议的侧边栏;永不出门)
//   notifyHost({type:'active', on})                     → 侧边栏 {t:'zoom_active', on} + 宿主回调(stdout 元数据)
//   notifyHost({type:'released', itemIds})              → 侧边栏 {t:'zoom_released_notice', itemIds} + 宿主回调
// Ember id:`zu_<RTMS user_id>`。侧边栏用 getUserContext().participantId 绑定到同一个 id(见 README「身份映射」,UNCONFIRMED)。
// 会议聊天:只有 Ember 自己广播的 `released` 文本,且 postReleasedToChat 开着,才发一条 {t:'zoom_post_chat'} 给
// 一个侧边栏(convener 优先),由它调 zoomSdk.sendMessageToChat。其它任何内容都不会去聊天。
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';

const EVENTS = new Set(['joined', 'left', 'name', 'audio', 'message', 'disconnected', 'transcript']);
export const zoomAgentId = (meetingUuid) => `zoom_ai_${createHash('sha256').update(String(meetingUuid)).digest('hex').slice(0, 10)}`;
export const zoomUserId = (rtmsUserId) => `zu_${String(rtmsUserId)}`;
const sidebarOnlyId = (uuid) => `zs_${createHash('sha256').update(String(uuid)).digest('hex').slice(0, 12)}`;

/**
 * @param {object} o
 * @param {string} o.meetingUuid
 * @param {import('./hub.mjs').SidebarHub} o.hub
 * @param {() => import('./rtms_client.mjs').RtmsClient} o.connect   join() 时调用,返回未 start 的 RtmsClient
 * @param {(ev: object) => void} [o.onHost]          notifyHost 的宿主侧回调(只有元数据)
 * @param {boolean} [o.postReleasedToChat]           released 文本是否交给侧边栏发会议聊天(缺省 false)
 * @param {() => string|null} [o.convenerId]         挑哪个侧边栏发聊天
 * @param {boolean} [o.allowSidebarOnly]             getUserContext 的 participantId 对不上 RTMS 时,是否给一个侧边栏专用 id(只能提问 / 签名,没有转写)
 */
export function zoomPort({ meetingUuid, hub, connect, onHost = () => {}, postReleasedToChat = false, convenerId = () => null, allowSidebarOnly = true, readyTimeoutMs = 30_000, log = () => {} } = {}) {
  if (!meetingUuid) throw new TypeError('zoomPort: meetingUuid required');
  if (!hub) throw new TypeError('zoomPort: hub required');
  if (typeof connect !== 'function') throw new TypeError('zoomPort: connect required');
  const selfId = zoomAgentId(meetingUuid);
  const bus = new EventEmitter();
  const people = new Map(); // id → name(仅内存)
  let client = null;
  let joined = false;
  let leaving = false;

  const fire = (ev, ...a) => bus.emit(ev, ...a);
  const seen = (rtmsUserId, name) => {
    if (rtmsUserId === '' || rtmsUserId === '0') return null; // MIXED 音频 user_id = 0:不是一个人
    const id = zoomUserId(rtmsUserId);
    if (!people.has(id)) { people.set(id, name || ''); fire('joined', id, name || ''); } else if (name && people.get(id) !== name) { people.set(id, name); fire('name', id, name); }
    return id;
  };

  const port = {
    selfId,
    transcripts: true,
    meetingUuid,
    isHuman: (id) => typeof id === 'string' && id !== selfId && (id.startsWith('zu_') || id.startsWith('zs_')),
    on(ev, fn) {
      if (!EVENTS.has(ev)) throw new TypeError(`zoomPort: unknown event ${ev}`);
      bus.on(ev, fn);
      return port;
    },
    participants: () => [...people].map(([id, name]) => ({ id, name })),
    nameOf: (id) => people.get(id) ?? '',
    async send(obj, to = null) {
      hub.sendTo(meetingUuid, obj, to);
      if (postReleasedToChat && to === null && obj?.t === 'released' && typeof obj.text === 'string') {
        // 唯一能去会议聊天的内容:k 人签名放行后的纪要原文。只交给一个侧边栏去发,免得每人都发一遍。
        const ids = hub.boundIds(meetingUuid);
        const target = ids.includes(convenerId()) ? convenerId() : ids[0];
        if (target) hub.sendTo(meetingUuid, { t: 'zoom_post_chat', draftId: obj.draftId, text: obj.text }, target);
      }
    },
    notifyHost(ev) {
      if (ev?.type === 'active') {
        hub.sendTo(meetingUuid, { t: 'zoom_active', on: ev.on === true }, null, { unbound: true });
        return onHost({ type: 'active', on: ev.on === true });
      }
      if (ev?.type === 'released' && Array.isArray(ev.itemIds)) {
        hub.sendTo(meetingUuid, { t: 'zoom_released_notice', itemIds: ev.itemIds });
        return onHost({ type: 'released', itemIds: [...ev.itemIds] });
      }
      return undefined;
    },
    async join() {
      if (joined) return port;
      joined = true;
      client = connect();
      client.on('join', (p) => seen(p.userId, p.userName));
      client.on('leave', (p) => {
        const id = zoomUserId(p.userId);
        if (!people.has(id)) return;
        people.delete(id);
        fire('left', id);
      });
      client.on('transcript', (t) => { const id = seen(t.userId, t.userName); if (id) fire('transcript', id, t.text); });
      client.on('audio', (a) => { const id = seen(a.userId, a.userName); if (id) fire('audio', id, a.pcm, a.sampleRate, a.channels); });
      client.on('reconnecting', (r) => log(`rtms reconnecting #${r.attempt} in ${r.delayMs} ms (${r.why})`));
      client.on('stopped', (s) => { if (!leaving) fire('disconnected', s?.stopReasonName ?? s?.reason ?? 'stopped', s); });
      hub.attachPort(meetingUuid, port);
      client.start();
      await client.waitReady(readyTimeoutMs);
      return port;
    },
    async leave() {
      if (leaving) return;
      leaving = true;
      try { client?.stop('ember_left'); } catch { /* */ }
      hub.sendTo(meetingUuid, { t: 'zoom_stop_rtms' }, null, { unbound: true }); // 让侧边栏顺手 zoomSdk.stopRTMS()(Zoom 侧的「应用正在接收」提示随之消失)
      hub.detachPort(meetingUuid, port);
      people.clear();
    },
    // ── hub 面(不属于 Ember port 形状)──
    /// 侧边栏 hello → Ember id。participantId 对得上 RTMS user_id 优先;其次唯一同名;否则侧边栏专用 id。
    _bindSidebar(hello) {
      if (!hello) return null;
      if (hello.participantId) {
        const id = zoomUserId(hello.participantId);
        if (!people.has(id)) { people.set(id, hello.screenName || ''); fire('joined', id, hello.screenName || ''); }
        return id;
      }
      const same = hello.screenName ? [...people].filter(([, n]) => n === hello.screenName) : [];
      if (same.length === 1) return same[0][0];
      if (!allowSidebarOnly || !hello.participantUUID) return null;
      const id = sidebarOnlyId(hello.participantUUID);
      if (!people.has(id)) { people.set(id, hello.screenName || ''); fire('joined', id, hello.screenName || ''); }
      return id;
    },
    _fromSidebar(id, msg) { fire('message', id, msg); },
    get rtms() { return client; },
  };
  return port;
}
