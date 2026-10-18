// 测试替身:FakeRoom(LaresRoom 事件面 + lares.anon 收发记录)、客户端签名、录 prompt 的 LLM。
import { randomBytes } from 'node:crypto';
import { generateEd25519, signEd25519, approvalMessage } from '../../../anonym-agent/core/crypto.mjs';
import { tone, ROOM_RATE } from '../../voice-agent/audio.mjs';

export class FakeRoom {
  constructor(people = []) {
    this.handlers = {};
    this.sent = []; // {obj, to}
    this.server = []; // 信令 anon_* 消息
    this.people = new Map(people.map((p) => [p.id, p.name]));
    this.left = false;
  }
  on(k, cb) { (this.handlers[k] ??= []).push(cb); return this; }
  fire(k, ...a) { for (const h of this.handlers[k] ?? []) h(...a); }
  async join() { return this; }
  async leave() { this.left = true; }
  nameOf(id) { return this.people.get(id) ?? ''; }
  participants() { return [...this.people].map(([id, name]) => ({ id, name })); }
  async publishAnon(obj, to = null) { this.sent.push({ obj: JSON.parse(JSON.stringify(obj)), to }); }
  notifyServer(msg) { this.server.push(JSON.parse(JSON.stringify(msg))); }
  // 场景驱动
  enter(id, name) { this.people.set(id, name); this.fire('joined', id); this.fire('names', id, name); }
  exit(id) { this.people.delete(id); this.fire('left', id); }
  msg(from, obj) { this.fire('anon', from, obj); }
  of(t) { return this.sent.filter((s) => s.obj.t === t).map((s) => s.obj); }
  last(t) { const xs = this.of(t); return xs[xs.length - 1]; }
}

export function client(id) {
  const kp = generateEd25519();
  return {
    id, kp, pubKey: kp.pubB64,
    approve(state, draft, nonce = randomBytes(16).toString('base64url')) {
      const sig = signEd25519(kp.privateKey, approvalMessage({ sid: state.sid, draftId: draft.draftId, draftHash: draft.draftHash, nonce }));
      return { t: 'approve', draftId: draft.draftId, draftHash: draft.draftHash, nonce, sig };
    },
  };
}

export const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));
export async function until(fn, ms = 3000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { const v = await fn(); if (v) return v; await tick(10); }
  throw new Error('until: timed out');
}

/// 一段「说话」:300 ms 正弦 + 400 ms 静音,10 ms 一帧 @48k
export function* speechFrames() {
  const n = ROOM_RATE / 100;
  const on = tone(ROOM_RATE, 300, { amp: 9000 });
  for (let i = 0; i + n <= on.length; i += n) yield on.subarray(i, i + n);
  for (let i = 0; i < 40; i++) yield new Int16Array(n);
}

/// 录下所有 prompt 的 LLM;handler 按 system prompt 识别调用并返回 JSON
export function recordingLLM(handler) {
  const calls = [];
  return {
    calls,
    allText: () => calls.map((c) => c.messages.map((m) => m.content).join('\n')).join('\n----\n'),
    async chat(messages, opts = {}) {
      calls.push({ messages: messages.map((m) => ({ ...m })), opts });
      const out = await handler(messages, opts, calls.length - 1);
      return { text: typeof out === 'string' ? out : JSON.stringify(out), usage: {}, finish: 'stop' };
    },
  };
}

/// 一个够用的脚本:L3 → 每行一条 entry(把「我」改写掉);minutes → 按 entry 出条目;路由 / L4 / answer 各给合法 JSON
export function scriptedHandler(messages) {
  const sys = messages.find((m) => m.role === 'system')?.content ?? '';
  const user = messages.filter((m) => m.role === 'user').map((m) => m.content).join('\n');
  if (/rewrite lines of a live/.test(sys)) {
    const lines = user.split('\n').filter((l) => /^P\d+: /.test(l));
    return { entries: lines.map((l) => { const [p, ...rest] = l.split(': '); return { p, text: `${p} 认为${rest.join(': ').replace(/我们?/g, '')}`, kind: 'idea', topic: '方案讨论', flags: [] }; }) };
  }
  if (/route a meeting/.test(sys)) return { skill: /纪要|minutes/.test(user) ? 'minutes' : 'answer' };
  if (/exportable minutes/.test(sys)) {
    const lines = user.split('\n').filter((l) => l.startsWith('- '));
    return { sections: [{ topic: '方案讨论', items: lines.map((l) => ({ kind: 'idea', text: l.replace(/^- (\[[^\]]*\] )?/, ''), flags: [] })) }] };
  }
  if (/review lines of an anonymised meeting digest/.test(sys)) return { results: [] };
  if (/assistant sitting in a private/.test(sys)) return { answer: '账本显示有参与者主张先做试点。' };
  if (/Rewrite the given line/.test(sys)) return { text: '有观点认为应当稳妥推进。' };
  return {};
}
