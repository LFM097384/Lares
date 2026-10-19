// 灶语 · port 接口(平台适配层)。完整说明见 ./PORT.md。
// 本体只通过 port 与「房间」打交道:收人声 / 文字 / 名字 / 进出,发字幕 / 文字 / 状态,以及发布一条出站音轨。
// 不认识任何平台(Lares、LiveKit、Zoom…);平台插件实现 port,本体实现回合引擎。

/// port.on(event, fn) 必须支持的事件与回调签名
export const PORT_EVENTS = Object.freeze({
  audio: '(identity, pcm: Int16Array, sampleRate, channels) 一位参与者的一帧入站音频',
  chat: '(msg: {id?, senderId, senderName?, body, bot?: boolean}) 一条文字消息',
  name: '(identity, displayName) 得知 / 更新参与者显示名',
  joined: '(identity) 有人进来(本体会补发一次当前状态)',
  left: '(identity) 有人离开',
  capctl: "(identity, msg: {t:'capack'|'capreq', ...}) 字幕控制(谁要 / 谁同意被转写)",
  disconnected: '(reason) 与房间断开(本体不处理,留给插件决定退出码)',
});

/// 出站音频格式:48 kHz、单声道、Int16,10 ms 一帧(480 样本)
export const OUT_RATE = 48000;
export const OUT_FRAME_SAMPLES = 480;

const REQUIRED_FNS = ['on', 'join', 'leave', 'audioOut', 'sendChat', 'publishCaption'];

/// 检查 port 是否满足接口;不满足抛 TypeError(列出缺的成员)。返回 port 本身。
export function checkPort(port) {
  if (!port || typeof port !== 'object') throw new TypeError('hearthvoice: port must be an object');
  const missing = REQUIRED_FNS.filter((k) => typeof port[k] !== 'function');
  if (typeof port.selfId !== 'string' || !port.selfId) missing.push('selfId');
  for (const k of ['isHuman', 'publishState', 'rename']) if (port[k] !== undefined && typeof port[k] !== 'function') missing.push(`${k} (must be a function)`);
  if (missing.length) throw new TypeError(`hearthvoice: port is missing ${missing.join(', ')}`);
  return port;
}

/// 测试 / 联调用的内存 port:记录所有出站内容,emit(ev, ...a) 模拟入站事件。
export function memoryPort({ selfId = 'hv_self', isHuman } = {}) {
  const handlers = new Map();
  const out = { frames: [], cleared: 0, chats: [], caps: [], states: [], names: [] };
  const port = {
    selfId,
    ...(isHuman ? { isHuman } : {}),
    joined: false,
    left: false,
    out,
    on(ev, fn) {
      if (!(ev in PORT_EVENTS)) throw new Error(`unknown port event ${ev}`);
      if (!handlers.has(ev)) handlers.set(ev, new Set());
      handlers.get(ev).add(fn);
      return () => handlers.get(ev)?.delete(fn);
    },
    emit(ev, ...a) { for (const fn of handlers.get(ev) ?? []) fn(...a); },
    async join() { port.joined = true; },
    async leave() { port.left = true; },
    audioOut() {
      return {
        captureFrame: (f) => { out.frames.push(f); },
        clear: () => { out.cleared += 1; },
        queuedMs: () => 0,
      };
    },
    sendChat: (t) => { out.chats.push(t); },
    publishCaption: (c) => { out.caps.push(c); },
    publishState: (f) => { out.states.push(f); },
    rename: (n) => { out.names.push(n); },
  };
  return port;
}
