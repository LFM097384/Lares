// AI 语音机器人(lares.ai-voice)单元测试。契约:server/bots/voice-agent/CONTRACT.md。
// 全部离线:只用 mock provider,不进房、不联网。
// 用法:node test/ai_voice.mjs

import { mkdtempSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { makeChecker, wait } from './lib/harness.mjs';
import { chunkForSpeech, IncrementalChunker, VOICE_CHUNKING, cleanForSpeech } from '../bots/voice-agent/chunker.mjs';
import { detectWake, detectPtt, parseWakeWords } from '../bots/voice-agent/wake.mjs';
import { CostGuard, truncateReply, maxTokensFor, localDay } from '../bots/voice-agent/caps.mjs';
import { spokenUntilFromPlayback, messagesAsExperienced, splitHeardAndUnsaid, History, playbackPosition } from '../bots/voice-agent/history.mjs';
import { resample, tone, EnergyVad, ROOM_RATE } from '../bots/voice-agent/audio.mjs';
import { VoiceAgent, Player } from '../bots/voice-agent/pipeline.mjs';
import { MockAsr, MockLlm, MockTts } from '../bots/voice-agent/providers/mock.mjs';
import { WarmPool } from '../bots/voice-agent/providers/index.mjs';
import { OpenAiCompatLlm } from '../bots/voice-agent/providers/openai_compat.mjs';
import { normalizeAiVoiceConfig, AI_VOICE_DEFAULTS } from '../bots/voice-agent/config.mjs';
import { parseArgs, loadConfig } from '../bots/voice-agent/index.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const T = makeChecker();
const { check } = T;
const squash = (s) => s.replace(/\s+/g, '');

// ── chunker ──────────────────────────────────────────────────────────────
const CORPUS = [
  '谢谢你的分享，这一点很有意思。能不能再具体说说，当时是什么让你做出这个决定的？你身边的人又是怎么看的呢？',
  'I see. That sounds like it mattered a lot to you. What changed after that? And if you could do it again, what would you do differently?',
  '好的。',
  '嗯，这个角度我之前没想到！我们换个话题吧：平时你会通过什么渠道了解这类信息？哪一个你最信任？',
  'Short. Then a much longer sentence that keeps going, with commas, clauses, and more clauses, until it is well past the maximum chunk length allowed for a single piece of speech, which forces a split.',
  'Version 2.5 is out; it fixes 3.14 bugs. Really? Yes.',
  '[sigh] 其实说实话，我也不太确定。[laugh] 可能就是运气吧……你觉得呢？',
  '没有标点的一整段话也要能处理而且不能丢字',
  '混合 mixed 文本, with 中文和 English. 第二句！Third one?',
];
const byChar = (t) => [...t];
const randomTokens = (seed) => (t) => {
  let s = seed;
  const rnd = () => { s = (s * 1103515245 + 12345) & 0x7fffffff; return s; };
  const parts = [];
  for (let i = 0; i < t.length;) { const n = 1 + (rnd() % 6); parts.push(t.slice(i, i + n)); i += n; }
  return parts;
};
const whole = (t) => [t];
function feedAll(text, splitter, cfg) {
  const c = new IncrementalChunker(cfg);
  const out = [];
  for (const tok of splitter(text)) out.push(...c.feed(tok));
  out.push(...c.flush());
  return out;
}

function chunkerTests() {
  console.log('\n[断句]');
  const splitters = [byChar, randomTokens(1), randomTokens(7), whole];
  for (const cfg of [undefined, { first_clause: true, first_min_chars: 4 }, VOICE_CHUNKING]) {
    let eq = true;
    let kept = true;
    const bad = [];
    for (const text of CORPUS) {
      const batch = JSON.stringify(chunkForSpeech(text, cfg));
      const unmerged = JSON.stringify(chunkForSpeech(text, { ...(cfg ?? {}), merge_tail_below: 0 }));
      for (const sp of splitters) {
        const inc = feedAll(text, sp, cfg);
        const j = JSON.stringify(inc);
        if (j !== batch && j !== unmerged) { eq = false; bad.push({ text: text.slice(0, 20), inc, batch }); }
        if (squash(inc.join('')) !== squash(text)) { kept = false; bad.push({ dropped: text.slice(0, 20), inc }); }
      }
    }
    const label = cfg === undefined ? '默认' : cfg === VOICE_CHUNKING ? 'VOICE' : 'first_clause';
    check(eq, `增量 == 批量(或批量不并尾)[${label}]`, bad[0]);
    check(kept, `不丢字 [${label}]`, bad[0]);
  }
  {
    const c = new IncrementalChunker();
    let at = null;
    [...CORPUS[0]].forEach((ch, i) => { if (c.feed(ch).length && at === null) at = i; });
    check(at !== null && at < CORPUS[0].length - 10, '流没结束就吐出第一块');
  }
  {
    const c = new IncrementalChunker();
    check(c.feed('没有标点的一整段话').length === 0 && JSON.stringify(c.flush()) === JSON.stringify(['没有标点的一整段话']), '没有边界不吐,flush 全给');
  }
  {
    const text = '这是一个足够长的第一句话，用来测试。好的。';
    check(JSON.stringify(chunkForSpeech(text)) === JSON.stringify([text]), '批量:短尾并回');
    check(JSON.stringify(feedAll(text, byChar)) === JSON.stringify(['这是一个足够长的第一句话，用来测试。', '好的。']), '增量:前一块已发,短尾单独发');
  }
  {
    const c = new IncrementalChunker();
    const out = [];
    for (const ch of '谢谢你的分享，这一点很有意思。能') out.push(...c.feed(ch));
    check(JSON.stringify(out) === JSON.stringify(['谢谢你的分享，这一点很有意思。']), '块一终局就吐');
  }
  check(chunkForSpeech(CORPUS[0], { first_clause: true, first_min_chars: 4 })[0] === '谢谢你的分享，', 'first_clause:首块短');
  {
    const c = new IncrementalChunker({ first_clause: true, first_min_chars: 4 });
    const out = [];
    for (const ch of '嗯，明白了你的意思，那我') out.push(...c.feed(ch));
    check(JSON.stringify(out) === JSON.stringify(['嗯，明白了你的意思，']), 'first_clause:≥4 字的第一个逗号就发', out);
  }
  {
    const chunks = feedAll('Version 2.5 is out; it fixes 3.14 bugs. Really? Yes.', byChar);
    check(chunks.every((c) => !/\d\.$/.test(c)) && chunks.join(' ').includes('3.14') && chunks.join(' ').includes('2.5'), '小数 / 版本号不切', chunks);
  }
  {
    const long = '这'.repeat(300);
    const chunks = chunkForSpeech(long, VOICE_CHUNKING);
    check(chunks.every((c) => c.length <= VOICE_CHUNKING.max_chars) && chunks.join('') === long, '无标点长串按 max_chars 硬切');
  }
  check(cleanForSpeech('[sigh] **其实** 好吧 😀') === '其实 好吧', '清洗:标记 / Markdown / emoji', cleanForSpeech('[sigh] **其实** 好吧 😀'));
}

// ── wake ─────────────────────────────────────────────────────────────────
function wakeTests() {
  console.log('\n[唤醒词]');
  const cfg = { name: '小助手', wakeWords: '小助手' };
  const q = (t, c = cfg) => detectWake(t, c);
  check(q('小助手，今天天气怎么样？').hit && q('小助手，今天天气怎么样？').query === '今天天气怎么样？', '句首命中 + 去掉唤醒词', q('小助手，今天天气怎么样？'));
  check(q('嗯，那个小助手你好').hit && q('嗯，那个小助手你好').query === '你好', '跳过语气词', q('嗯，那个小助手你好'));
  check(q('今天几号啊小助手').hit && q('今天几号啊小助手').query === '今天几号啊', '句末也命中', q('今天几号啊小助手'));
  check(q('小 助 手, 帮我算一下').hit, '中间有空格 / 半角标点');
  for (const v of ['小组手', '小主手', '晓助手', '小助首']) check(q(`${v}，讲个笑话`).hit && q(`${v}，讲个笑话`).query === '讲个笑话', `同音:${v}`, q(`${v}，讲个笑话`));
  check(q('小猪手，讲个笑话').hit, '≥3 字允许错 1 个任意字(句首)');
  check(!q('今天的小猪手很好吃哦对吧真的').hit, '句中近似词不触发');
  check(!q('我们去吃饭吧').hit && !q('').hit && !q('，。').hit, '不相关 / 空 / 纯标点不触发');
  check(!q('大猪脚，讲个笑话').hit, '错 2 字不触发');
  check(q('小助手').hit && q('小助手').query === '', '只喊名字:hit 但 query 为空');
  const c2 = { name: 'Lulu', wakeWords: '炉灵, hey lares、阿福' };
  check(JSON.stringify(parseWakeWords(c2.name, c2.wakeWords).sort()) === JSON.stringify(['heylares', 'lulu', '炉灵', '阿福'].sort()), '解析多个唤醒词', parseWakeWords(c2.name, c2.wakeWords));
  check(q('LULU, what time is it?', c2).hit && q('LULU, what time is it?', c2).query === 'what time is it?', '拉丁名大小写不敏感', q('LULU, what time is it?', c2));
  check(q('卢灵，几点了', c2).hit, '同音:卢灵 → 炉灵');
  check(q('阿福在吗', c2).hit && q('阿福在吗', c2).query === '在吗', '额外唤醒词');
  console.log('\n[ptt]');
  check(detectPtt('@AI 今天吃什么', cfg).hit && detectPtt('@AI 今天吃什么', cfg).query === '今天吃什么', '@AI');
  check(detectPtt('＠ai，你好', cfg).query === '你好', '全角 @ + 小写');
  check(detectPtt('@小助手 讲个故事', cfg).query === '讲个故事', '@名字');
  check(!detectPtt('@AIR 怎么样', cfg).hit, '@AIR 不算');
  check(!detectPtt('你好 @AI', cfg).hit && !detectPtt('@张三 你好', cfg).hit, '不在开头 / @别人 不算');
}

// ── caps ─────────────────────────────────────────────────────────────────
function capsTests() {
  console.log('\n[费用护栏]');
  const dir = mkdtempSync(path.join(tmpdir(), 'aiv-'));
  const file = path.join(dir, 'sub', 'usage.json');
  const clock = { t: Date.UTC(2026, 8, 15, 4, 0, 0) };
  const events = [];
  const cfg = { maxTurnsPerHour: 3, maxTurnsPerDay: 5, maxReplyChars: 100 };
  const g = new CostGuard({ now: () => clock.t, usageFile: file, tzOffsetMin: 480, config: cfg, emit: (e) => events.push(e) });
  for (let i = 0; i < 3; i++) { check(g.check().ok, `第 ${i + 1} 轮放行`); g.recordTurn(); clock.t += 60_000; }
  const h = g.check();
  check(!h.ok && h.reason === 'hourly' && h.retryInMs > 0 && h.retryInMs <= 3_600_000, '每小时上限', h);
  clock.t += 58 * 60_000 + 1; // 第一轮滑出窗口
  check(g.check().ok, '滑动窗口:最早一轮过期后放行');
  g.recordTurn();
  clock.t += 2 * 3_600_000;
  g.recordTurn();
  check(events.some((e) => e.ev === 'cap_reached' && e.scope === 'daily'), '到每日上限发 cap_reached');
  check(!g.check().ok && g.check().reason === 'daily', '每日上限');
  g.addUsage({ llmIn: 10, llmOut: 20, ttsChars: 30, asrSec: 1.25 });
  check(events.some((e) => e.ev === 'usage' && e.llmOut === 20 && e.total.ttsChars === 30), 'usage 事件');
  check(existsSync(file), '持久化到 LARES_AI_USAGE_FILE');
  const g2 = new CostGuard({ now: () => clock.t, usageFile: file, tzOffsetMin: 480, config: cfg });
  check(g2.turnsToday() === 5 && !g2.check().ok, '重启后每日计数还在');
  const day = localDay(clock.t, 480);
  check(JSON.parse(readFileSync(file, 'utf8')).days[day].turns === 5, '按本地日记账', JSON.parse(readFileSync(file, 'utf8')));
  // 过了本地午夜(UTC+8 的 0 点 = UTC 16:00)
  clock.t = Date.UTC(2026, 8, 15, 16, 0, 1);
  check(g2.check().ok && g2.turnsToday() === 0, '本地新的一天清零');
  check(localDay(Date.UTC(2026, 8, 15, 15, 59), 480) === '2026-09-15' && localDay(Date.UTC(2026, 8, 15, 16, 0), 480) === '2026-09-16', 'localDay 时区');
  // 截断
  const long = '第一句话说完了。第二句话也说完了。第三句话还没说完就超了长度限制';
  const t30 = truncateReply(long, 20);
  check([...t30].length <= 20 && t30.endsWith('。'), '截断在句末', t30);
  check(truncateReply('短句。', 20) === '短句。', '不超长不动');
  const hard = truncateReply('没有标点的一大段话一直说一直说一直说一直说', 10);
  check([...hard].length === 10 && hard.endsWith('…'), '无标点硬截加省略号', hard);
  check(maxTokensFor(120) >= 120 && maxTokensFor(20) >= 32, 'max_tokens 由字数推');
}

// ── history ──────────────────────────────────────────────────────────────
function historyTests() {
  console.log('\n[听到了什么]');
  const STORED = '谢谢你的分享。能不能再具体说说？你身边的人怎么看？';
  const CHUNKS = ['谢谢你的分享。', '能不能再具体说说？', '你身边的人怎么看？'];
  check(spokenUntilFromPlayback(STORED, CHUNKS, 1, 0) === '谢谢你的分享。'.length, '块间:只算播完的');
  const mid = spokenUntilFromPlayback(STORED, CHUNKS, 1, 0.5);
  check(mid > 7 && mid < 16, '块中:按比例(CJK 逐字)', mid);
  check(spokenUntilFromPlayback(STORED, CHUNKS, 2, 1) === STORED.length && spokenUntilFromPlayback(STORED, CHUNKS, 5, 0) === STORED.length, '播完 / 越界');
  check(spokenUntilFromPlayback(STORED, CHUNKS, 0, 0) === 0 && spokenUntilFromPlayback(STORED, CHUNKS, null, null) === 0, '什么都没听到');
  const st = 'That is interesting. Could you tell me more about the decision?';
  const ch = ['That is interesting.', 'Could you tell me more about the decision?'];
  let ok = true;
  for (let i = 0; i <= 20; i++) {
    const su = spokenUntilFromPlayback(st, ch, 1, i / 20);
    if (!(su === st.length || su === 0 || !(/[A-Za-z0-9]/.test(st[su - 1]) && /[A-Za-z0-9]/.test(st[su])))) ok = false;
  }
  check(ok, '拉丁词不从中间切');
  for (const f of [-3, 7, NaN, 'x']) {
    const su = spokenUntilFromPlayback(STORED, CHUNKS, 1, f);
    check(su >= 0 && su <= STORED.length, `坏比例被夹紧 (${String(f)})`);
  }
  const raw = ['[sigh] 其实说实话，我也不太确定。', '[laugh] 可能就是运气吧。'];
  const stored = cleanForSpeech(raw.join(''));
  check(stored.slice(0, spokenUntilFromPlayback(stored, raw, 1, 0)) === '其实说实话，我也不太确定。', '带标记的块映射到清洗后的文本');
  const hh = [
    { role: 'user', content: 'a' },
    { role: 'assistant', content: '第一句。第二句。', interrupted: true, spokenUntil: 4 },
    { role: 'user', content: 'b' },
    { role: 'assistant', content: '没说出口', interrupted: true, spokenUntil: 0 },
  ];
  check(JSON.stringify(messagesAsExperienced(hh)) === JSON.stringify([{ role: 'user', content: 'a' }, { role: 'assistant', content: '第一句。' }, { role: 'user', content: 'b' }]), 'messagesAsExperienced');
  check(JSON.stringify(splitHeardAndUnsaid(hh[1])) === JSON.stringify(['第一句。', '第二句。']), 'splitHeardAndUnsaid');
  const p = playbackPosition([100, 200, 300], 150);
  check(p.chunkIndex === 1 && Math.abs(p.fraction - 0.25) < 1e-9, 'playbackPosition');
  const H = new History(2);
  for (let i = 0; i < 5; i++) { H.addUser(`u${i}`); H.addAssistant(`a${i}`); }
  check(H.items.length === 4 && H.items[0].content === 'u3', '只留最近 N 轮');
}

// ── audio / vad / pool ───────────────────────────────────────────────────
async function audioTests() {
  console.log('\n[音频 / VAD / 连接池]');
  const s = tone(48000, 100);
  check(resample(s, 48000, 16000).length === 1600 && resample(tone(24000, 100), 24000, 48000).length === 4800, '重采样长度');
  const vad = new EnergyVad({ hangoverMs: 300 });
  let onset = false;
  let ended = false;
  for (let i = 0; i < 30; i++) vad.push(new Int16Array(160), 10);
  for (let i = 0; i < 30; i++) if (vad.push(tone(16000, 10), 10).onset) onset = true;
  const runMs = vad.runMs;
  for (let i = 0; i < 60; i++) if (vad.push(new Int16Array(160), 10).ended) ended = true;
  check(onset && runMs >= 250 && ended && !vad.active, 'VAD:起声 / 持续时长 / 拖尾后结束', { onset, runMs, ended });

  const clock = { t: 1000 };
  let n = 0;
  const pool = new WarmPool({ open: async () => ({ id: ++n, alive: true, used: false, openedAt: clock.t, close() { this.alive = false; } }), now: () => clock.t, maxIdleMs: 50_000 });
  pool.prewarm();
  await wait(5);
  const a = await pool.take();
  check(a.id === 1 && n === 2, '连接池:取热连接并立刻补一条');
  clock.t += 60_000;
  await wait(5);
  const b = await pool.take();
  check(b.id === 3, '连接池:过期的备用不用', b.id);
  pool.stop();
}

// ── 完整回合(mock) ────────────────────────────────────────────────────────
function makeHarness({ config = {}, llm = {}, tts = {}, asr = {}, paceScale = 0.25, usageFile = null, agentOpts = {} } = {}) {
  const frames = [];
  const caps = [];
  const chats = [];
  const events = [];
  const states = [];
  let cleared = 0;
  const sink = { captureFrame: (f) => { frames.push(f); }, clear: () => { cleared++; }, queuedMs: () => 0 };
  const providers = { asr: new MockAsr(asr), llm: new MockLlm(llm), tts: new MockTts(tts) };
  const cfg = normalizeAiVoiceConfig(config).config;
  const agent = new VoiceAgent({
    config: cfg,
    providers,
    sink,
    room: { publishCaption: (c) => caps.push(c), sendChat: (t) => chats.push(t), publishState: (s) => states.push(s) },
    selfIdentity: 'u_ai_self',
    emit: (e) => events.push(e),
    guard: new CostGuard({ config: cfg, usageFile, emit: (e) => events.push(e) }),
    paceScale,
    ...agentOpts,
  });
  agent.setName('u_alice', 'Alice');
  return { agent, frames, caps, chats, events, states, providers, sink, get cleared() { return cleared; } };
}

/// 以 10ms 帧给 agent 喂一段「人声」:静音 → 有声 ms → 静音
async function speak(h, identity, ms, { lead = 100, tail = 1300, realtime = 1 } = {}) {
  const fr = (pcm) => h.agent.onAudioFrame(identity, pcm, 48000, 1);
  for (let t = 0; t < lead; t += 10) fr(new Int16Array(480));
  for (let t = 0; t < ms; t += 10) { fr(tone(48000, 10, { freq: 200, amp: 9000 })); if (t % 50 === 0) await wait(realtime * 5); }
  for (let t = 0; t < tail; t += 10) { fr(new Int16Array(480)); if (t % 50 === 0) await wait(realtime * 5); }
}

async function untilEv(h, pred, ms = 8000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { const e = h.events.find(pred); if (e) return e; await wait(10); }
  return null;
}

async function pipelineTests() {
  console.log('\n[回合引擎(mock)]');
  {
    const h = makeHarness({ asr: { script: ['小助手，今天天气怎么样？'] }, llm: { reply: '今天天气不错，适合出门散步。记得带伞哦，下午可能有阵雨。' } });
    await speak(h, 'u_alice', 600);
    const turn = await untilEv(h, (e) => e.ev === 'turn');
    check(!!turn, '一轮结束发 turn 事件', h.events);
    if (turn) {
      const keys = ['id', 'trigger', 'asrFinalAt', 'llmFirstTokenMs', 'firstSentenceMs', 'ttsFirstAudioMs', 'ttfaMs', 'replyChars', 'heardChars', 'interrupted'];
      check(keys.every((k) => k in turn), 'turn 事件字段齐全', turn);
      check(turn.trigger === 'wake' && !turn.interrupted && turn.replyChars === turn.heardChars && turn.replyChars > 10, 'wake 触发、未打断、全部听到', turn);
      check(turn.llmFirstTokenMs <= turn.firstSentenceMs && turn.firstSentenceMs <= turn.ttsFirstAudioMs && turn.ttsFirstAudioMs <= turn.ttfaMs, '延迟递增:llm → 首块 → TTS 首音 → 首帧', turn);
      check(!('reply' in turn) && !('query' in turn), 'turn 不带正文(默认)');
    }
    const capFrames = h.caps;
    check(capFrames.length >= 2 && new Set(capFrames.map((c) => c.id)).size === 1 && capFrames.at(-1).final === true, '字幕:一轮一个 id,最后 final', capFrames);
    check(capFrames.every((c, i) => c.t === 'cap' && c.seq === i + 1), '字幕 seq 递增');
    check(capFrames.at(-1).text === '今天天气不错，适合出门散步。记得带伞哦，下午可能有阵雨。', '最终字幕 = 完整回复', capFrames.at(-1));
    check(h.chats.length === 1 && h.chats[0] === capFrames.at(-1).text, '回复发到聊天', h.chats);
    check(h.frames.length > 50 && h.frames.every((f) => f.length === 480), '10ms 48k 帧送进 sink', h.frames.length);
    const um = h.providers.llm.calls[0].messages;
    check(um[0].role === 'system' && um.at(-1).content === 'Alice: 今天天气怎么样？', 'LLM 收到「名字: 问题」', um.at(-1));
    check(h.providers.llm.calls[0].maxTokens === maxTokensFor(120), 'max_tokens 由 maxReplyChars 推');
    check(h.events.some((e) => e.ev === 'usage' && e.ttsChars > 0), 'usage 事件(TTS 字数)');
    // 第二轮:历史里有上一轮
    h.providers.asr.script = ['小助手，那明天呢'];
    await speak(h, 'u_alice', 500);
    await untilEv(h, (e) => e.ev === 'turn' && e !== turn);
    const m2 = h.providers.llm.calls[1]?.messages ?? [];
    check(m2.length === 4 && m2[2].role === 'assistant', '第二轮带上历史', m2.map((m) => m.role));
    await h.agent.close();
  }
  {
    const h = makeHarness({ asr: { script: ['今天吃什么好呢'] } });
    await speak(h, 'u_alice', 500);
    await wait(400);
    check(!h.events.some((e) => e.ev === 'turn') && h.providers.llm.calls.length === 0, 'wake 模式:没叫名字不回答');
    // 只喊名字,下一句当问题
    h.providers.asr.script = ['小助手', '讲个笑话'];
    h.providers.asr.counts.clear();
    await speak(h, 'u_alice', 400);
    await speak(h, 'u_alice', 400);
    await untilEv(h, (e) => e.ev === 'turn');
    check(h.providers.llm.calls[0]?.messages.at(-1).content === 'Alice: 讲个笑话', '只喊名字 → 下一句当问题', h.providers.llm.calls[0]?.messages.at(-1));
    await h.agent.close();
  }
  {
    const h = makeHarness({ config: { trigger: 'always' }, asr: { script: ['今天吃什么好呢'] } });
    await speak(h, 'u_alice', 500);
    const t = await untilEv(h, (e) => e.ev === 'turn');
    check(t?.trigger === 'always', 'always 模式:说完就回答');
    await h.agent.close();
  }
  {
    const h = makeHarness({ config: { trigger: 'ptt' }, asr: { script: ['小助手，在吗'] } });
    await speak(h, 'u_alice', 500);
    await wait(300);
    check(h.providers.llm.calls.length === 0, 'ptt 模式:语音不触发');
    h.agent.onChat({ senderId: 'u_bob', senderName: 'Bob', body: '@AI 一加一等于几' });
    const t = await untilEv(h, (e) => e.ev === 'turn');
    check(t?.trigger === 'ptt' && h.providers.llm.calls[0].messages.at(-1).content === 'Bob: 一加一等于几', 'ptt:@AI 聊天触发', h.providers.llm.calls[0]?.messages.at(-1));
    h.agent.onChat({ senderId: 'x', bot: true, body: '@AI 机器人消息' });
    await wait(100);
    check(h.providers.llm.calls.length === 1, '机器人消息不触发');
    await h.agent.close();
  }
  {
    // 自己 / capack:false 的成员不进 ASR
    const h = makeHarness({ config: { trigger: 'always' } });
    await speak(h, 'u_ai_self', 300);
    h.agent.onCaptionControl('u_carol', { t: 'capack', on: false });
    await speak(h, 'u_carol', 300);
    await wait(300);
    check(h.providers.asr.sessions === 0, '不听自己 / 不转写拒绝字幕的成员', h.providers.asr.sessions);
    h.agent.onCaptionControl('u_carol', { t: 'capack', on: true });
    await speak(h, 'u_carol', 300);
    check(h.providers.asr.sessions === 1, 'capack:true 后恢复');
    await h.agent.close();
  }
  {
    // 打断:长回复,播到一半有人插话
    const reply = '好的，我给你讲一个很长很长的故事。从前有座山，山里有座庙，庙里有个老和尚在给小和尚讲故事。讲的是什么呢？还是从前有座山。';
    const h = makeHarness({ config: { maxReplyChars: 200 }, asr: { script: ['小助手，讲个故事', '等一下'] }, llm: { reply }, tts: { msPerChar: 60 }, paceScale: 1 });
    await speak(h, 'u_alice', 400);
    // 等它开口播一会儿
    const t0 = Date.now();
    while (h.frames.length < 80 && Date.now() - t0 < 5000) await wait(10);
    const framesBefore = h.frames.length;
    const onset = Date.now();
    let stoppedAt = null;
    const fr = (pcm) => h.agent.onAudioFrame('u_alice', pcm, 48000, 1);
    for (let i = 0; i < 60 && stoppedAt === null; i++) {
      fr(tone(48000, 10, { freq: 200, amp: 9000 }));
      await wait(10);
      if (h.cleared > 0) stoppedAt = Date.now();
    }
    const turn = await untilEv(h, (e) => e.ev === 'turn');
    check(framesBefore >= 80, '打断前已经在播', framesBefore);
    check(stoppedAt !== null && stoppedAt - onset < 500, `插话后 <500ms 停(实测 ${stoppedAt && stoppedAt - onset}ms)`);
    const framesAt = h.frames.length;
    await wait(200);
    check(h.frames.length === framesAt, '停了之后不再送帧');
    check(turn?.interrupted === true && turn.heardChars > 0 && turn.heardChars < turn.replyChars, 'turn:interrupted,只听到一部分', turn);
    const last = h.agent.history.items.at(-1);
    check(last?.role === 'assistant' && last.interrupted && reply.startsWith(last.content.slice(0, last.spokenUntil)), '历史记下打断位置', last);
    const exp = h.agent.history.messages().at(-1);
    check(exp.role === 'assistant' && exp.content.length < reply.length && reply.startsWith(exp.content), '给 LLM 的历史只含听到的部分', exp);
    check(h.chats.length === 1 && h.chats[0].endsWith('…') && h.chats[0].length < reply.length, '聊天只发听到的部分 + …', h.chats);
    check(h.caps.at(-1).final && h.caps.at(-1).text.endsWith('…'), '最终字幕 = 听到的部分 + …');
    check(h.providers.tts.closed >= 1, '打断时关掉 TTS 连接');
    await h.agent.close();
  }
  {
    // interrupt:false → 不打断
    const h = makeHarness({ config: { interrupt: false }, asr: { script: ['小助手，说点什么'] }, llm: { reply: '好的，这是一段不会被打断的话，一直说到结束为止。' } });
    await speak(h, 'u_alice', 400);
    const t0 = Date.now();
    while (h.frames.length < 20 && Date.now() - t0 < 5000) await wait(10);
    for (let i = 0; i < 40; i++) { h.agent.onAudioFrame('u_bob', tone(48000, 10, { amp: 9000 }), 48000, 1); await wait(5); }
    const turn = await untilEv(h, (e) => e.ev === 'turn');
    check(turn && !turn.interrupted && h.cleared === 0, 'interrupt=false 时插话不停', turn);
    await h.agent.close();
  }
  {
    // 回复长度上限
    const h = makeHarness({ config: { maxReplyChars: 20 }, asr: { script: ['小助手，说长一点'] }, llm: { reply: '这是第一句话。这是第二句话，比较长一些。这是第三句话，会被截掉。' } });
    await speak(h, 'u_alice', 400);
    const turn = await untilEv(h, (e) => e.ev === 'turn');
    check(turn && turn.replyChars <= 20 && h.chats[0] && [...h.chats[0]].length <= 20, 'maxReplyChars 截断', { turn, chat: h.chats[0] });
    await h.agent.close();
  }
  {
    // 每小时上限:第二轮被拒
    const h = makeHarness({ config: { maxTurnsPerHour: 1, trigger: 'always' }, asr: { script: ['第一个问题', '第二个问题'] }, llm: { reply: '好。' } });
    await speak(h, 'u_alice', 300);
    await untilEv(h, (e) => e.ev === 'turn');
    const sessionsBefore = h.providers.asr.sessions;
    await speak(h, 'u_alice', 300);
    const cap = await untilEv(h, (e) => e.ev === 'cap_reached', 2000);
    check(cap?.scope === 'hourly' && h.providers.llm.calls.length === 1, '每小时上限:拒绝并发 cap_reached', cap);
    check(h.providers.asr.sessions === sessionsBefore, '每小时上限:不再开 ASR 会话', { sessionsBefore, now: h.providers.asr.sessions });
    h.agent.onChat({ senderId: 'u_bob', senderName: 'Bob', body: '@AI 还在吗' });
    await wait(50);
    check(h.chats.some((c) => c.includes('稍后')) && h.providers.llm.calls.length === 1, '上限时 @AI 聊天收到一条提示');
    await h.agent.close();
  }
  {
    // 上限期间不开 ASR,但本地 VAD 打断照常;窗口腾出来后恢复识别
    const clock = { t: Date.UTC(2026, 8, 15, 4, 0, 0) };
    const logs = [];
    const reply = '好的，我给你讲一个很长很长的故事。从前有座山，山里有座庙，庙里有个老和尚在给小和尚讲故事。讲的是什么呢？';
    const frames = [];
    let cleared = 0;
    const events = [];
    const cfg = normalizeAiVoiceConfig({ maxTurnsPerHour: 1, maxReplyChars: 200, trigger: 'always' }).config;
    const asr = new MockAsr({ script: ['讲个故事', '又一个问题'] });
    const llm = new MockLlm({ reply });
    const agent = new VoiceAgent({
      config: cfg,
      providers: { asr, llm, tts: new MockTts({ msPerChar: 60 }) },
      sink: { captureFrame: (f) => { frames.push(f); }, clear: () => { cleared++; }, queuedMs: () => 0 },
      room: { publishCaption: () => {}, sendChat: () => {} },
      selfIdentity: 'u_ai_self',
      emit: (e) => events.push(e),
      guard: new CostGuard({ config: cfg, now: () => clock.t }),
      now: () => clock.t,
      log: (m) => logs.push(m),
      paceScale: 1,
    });
    const h = { agent, events, providers: { asr, llm } };
    await speak(h, 'u_alice', 400);
    const t0 = Date.now();
    while (frames.length < 60 && Date.now() - t0 < 5000) await wait(10);
    const sessionsAtCap = asr.sessions;
    for (let i = 0; i < 60 && cleared === 0; i++) { agent.onAudioFrame('u_alice', tone(48000, 10, { freq: 200, amp: 9000 }), 48000, 1); await wait(10); }
    const turn = await untilEv(h, (e) => e.ev === 'turn');
    check(cleared > 0 && turn?.interrupted === true, '上限期间:本地 VAD 打断照常', { cleared, turn });
    check(asr.sessions === sessionsAtCap && sessionsAtCap === 1, '上限期间:插话不开 ASR 会话', { sessionsAtCap, now: asr.sessions });
    const pauseLogs = logs.filter((m) => m.startsWith('ASR 暂停'));
    check(pauseLogs.length === 1 && !pauseLogs[0].includes('讲个故事'), '进入上限只记一行日志(不含正文)', logs);
    await speak(h, 'u_alice', 300);
    check(asr.sessions === 1, '上限期间:再说话也不开 ASR', asr.sessions);
    clock.t += 3_600_001; // 窗口腾出来
    llm.reply = '好。';
    await speak(h, 'u_alice', 300);
    const t2 = await untilEv(h, (e) => e.ev === 'turn' && e !== turn, 8000);
    check(asr.sessions === 2 && !!t2 && logs.filter((m) => m.startsWith('ASR 恢复')).length === 1, '窗口腾出后恢复 ASR 并回答', { sessions: asr.sessions, logs });
    await agent.close();
  }
  {
    // ptt 模式:一帧都不送 ASR,但打断照常
    const reply = '好的，我给你讲一个很长很长的故事。从前有座山，山里有座庙，庙里有个老和尚在给小和尚讲故事。讲的是什么呢？';
    const h = makeHarness({ config: { trigger: 'ptt', maxReplyChars: 200 }, llm: { reply }, tts: { msPerChar: 60 }, paceScale: 1 });
    let sent = 0;
    const open0 = h.providers.asr.open.bind(h.providers.asr);
    h.providers.asr.open = (o) => { const s = open0(o); const send0 = s.send.bind(s); s.send = (p) => { sent += p.length; send0(p); }; return s; };
    await speak(h, 'u_alice', 500);
    check(h.providers.asr.sessions === 0 && sent === 0, 'ptt:语音不送 ASR(0 会话 / 0 样本)', { sessions: h.providers.asr.sessions, sent });
    h.agent.onChat({ senderId: 'u_bob', senderName: 'Bob', body: '@AI 讲个故事' });
    const t0 = Date.now();
    while (h.frames.length < 60 && Date.now() - t0 < 5000) await wait(10);
    for (let i = 0; i < 60 && h.cleared === 0; i++) { h.agent.onAudioFrame('u_alice', tone(48000, 10, { freq: 200, amp: 9000 }), 48000, 1); await wait(10); }
    const turn = await untilEv(h, (e) => e.ev === 'turn');
    check(h.cleared > 0 && turn?.interrupted === true, 'ptt:本地 VAD 打断照常', turn);
    check(h.providers.asr.sessions === 0 && sent === 0, 'ptt:打断全程 0 ASR', { sessions: h.providers.asr.sessions, sent });
    await h.agent.close();
  }
  {
    // 运行时切配置:wake → ptt 关掉已开的 ASR 会话,之后不再开
    const h = makeHarness({ asr: { script: ['今天吃什么好呢'] } });
    let closed = 0;
    const open0 = h.providers.asr.open.bind(h.providers.asr);
    h.providers.asr.open = (o) => open0({ ...o, onClose: () => { closed++; o.onClose?.(); } });
    await speak(h, 'u_alice', 300, { tail: 200 });
    check(h.providers.asr.sessions === 1 && closed === 0, 'wake:说话时开了一个 ASR 会话', { s: h.providers.asr.sessions, closed });
    h.agent.setConfig(normalizeAiVoiceConfig({ trigger: 'ptt' }).config);
    await wait(20);
    check(closed === 1, 'setConfig wake→ptt:关掉已开的 ASR 会话', closed);
    await speak(h, 'u_alice', 300);
    check(h.providers.asr.sessions === 1, 'ptt 之后不再开会话', h.providers.asr.sessions);
    h.agent.setConfig(normalizeAiVoiceConfig({ trigger: 'always' }).config);
    await speak(h, 'u_alice', 300);
    check(h.providers.asr.sessions === 2, 'ptt→always:恢复识别', h.providers.asr.sessions);
    await h.agent.close();
  }
  {
    // 进行中再来一个请求:排队一个,结束后接着回答
    const h = makeHarness({ config: { trigger: 'always' }, llm: { reply: '好的，第一个回答说完了。' } });
    h.agent.onChat({ senderId: 'u1', senderName: 'A', body: '@AI 问题一' });
    await wait(30);
    h.agent.onChat({ senderId: 'u2', senderName: 'B', body: '@AI 问题二' });
    h.agent.onChat({ senderId: 'u3', senderName: 'C', body: '@AI 问题三' });
    const t0 = Date.now();
    while (h.events.filter((e) => e.ev === 'turn').length < 2 && Date.now() - t0 < 8000) await wait(20);
    await wait(300);
    const calls = h.providers.llm.calls.map((c) => c.messages.at(-1).content);
    check(calls.length === 2 && calls[1] === 'C: 问题三', '进行中只排一个(新的顶掉旧的)', calls);
    await h.agent.close();
  }
  {
    // TTS 不可用:退化为只发文字
    const h = makeHarness({ asr: { script: ['小助手，你好'] }, llm: { reply: '你好呀。' }, tts: { failOpen: 99 } });
    h.agent.pool.failures = 0;
    await speak(h, 'u_alice', 400);
    const turn = await untilEv(h, (e) => e.ev === 'turn');
    check(turn?.ttsFailed === true && h.chats[0] === '你好呀。' && h.frames.length === 0, 'TTS 失败 → 只发文字', { turn, chats: h.chats });
    await h.agent.close();
  }
  {
    // ASR 冷握手超时:失败一次后重试成功,整句音频(含 pre-roll)一样不少,照样出定稿并回答
    const opts = { config: { trigger: 'always' }, asr: { script: ['今天吃什么好呢'], handshakeMs: 40 }, llm: { reply: '好。' }, agentOpts: { asrRetryBackoffMs: 30 } };
    const base = makeHarness(opts);
    await wait(5);
    check(base.providers.asr.warmups === 1 && base.providers.asr.sessions === 0, '启动时 ASR 预热一次(不开会话、不送音频)', base.providers.asr);
    await speak(base, 'u_alice', 500);
    const t0 = await untilEv(base, (e) => e.ev === 'turn');
    const want = base.providers.asr.liveSamples;
    await base.agent.close();
    const h = makeHarness({ ...opts, asr: { ...opts.asr, failOpen: 1 } });
    await speak(h, 'u_alice', 500);
    const t1 = await untilEv(h, (e) => e.ev === 'turn');
    check(!!t0 && want > 16000, 'ASR 基线:握手后出定稿', { want, t0 });
    check(h.providers.asr.failedOpens === 1 && h.providers.asr.sessions === 2, 'ASR 握手失败一次 → 自动重开', h.providers.asr);
    check(!!t1 && h.providers.llm.calls[0]?.messages.at(-1).content === 'Alice: 今天吃什么好呢', '重试后照样出定稿并回答', h.providers.llm.calls[0]?.messages.at(-1));
    check(h.providers.asr.liveSamples === want, `重试不丢音频(含 pre-roll):${h.providers.asr.liveSamples}/${want} 样本`);
    await h.agent.close();
  }
  {
    // ASR 握手次次失败:重试 2 次后干净放弃(不残留会话 / 计时器),下一句照常重新连接
    const logs = [];
    const h = makeHarness({ config: { trigger: 'always' }, asr: { script: ['第一句', '第二句'], handshakeMs: 20, failOpen: 99 }, llm: { reply: '好。' }, agentOpts: { asrRetryBackoffMs: 20, log: (m) => logs.push(m) } });
    await speak(h, 'u_alice', 500);
    await wait(300);
    const sp = h.agent.speakers.get('u_alice');
    check(h.providers.asr.sessions === 3 && h.providers.asr.failedOpens === 3, '一直失败:首连 + 2 次重试后停', h.providers.asr);
    check(sp && sp.session === null && sp.retryTimer === null && sp.unacked.length === 0 && !h.events.some((e) => e.ev === 'turn'), '放弃后清干净,不回答', sp && { session: sp.session, retry: sp.retryTimer, unacked: sp.unacked.length });
    check(h.events.some((e) => e.ev === 'error' && e.where === 'asr') && logs.some((m) => m.includes('放弃')), '放弃时发 error 事件并记日志(不含正文)', logs);
    h.providers.asr.failOpen = 0;
    await speak(h, 'u_alice', 500);
    const t = await untilEv(h, (e) => e.ev === 'turn');
    check(h.providers.asr.sessions === 4 && !!t, '放弃之后下一句照常识别并回答', { sessions: h.providers.asr.sessions, t });
    await h.agent.close();
  }
  await aiStateTests();
  {
    // Player 绝对时间节拍
    const out = [];
    const p = new Player({ sink: { captureFrame: (f) => out.push([Date.now(), f]), clear() {} } });
    p.enqueue(0, tone(24000, 300), 24000);
    p.endInput();
    const t0 = Date.now();
    await p.drained;
    const dt = Date.now() - t0;
    check(out.length === 30 && dt >= 270 && dt < 450, `Player:24k→48k、30 帧、实时节拍(${dt}ms)`, out.length);
    check(new Set(out.map(([, f]) => f.buffer)).size === out.length, 'Player:每帧独立 buffer(不是 subarray 视图)');
  }
}

// ── lares.ai 状态帧(CONTRACT §5) ─────────────────────────────────────────
async function aiStateTests() {
  console.log('\n[lares.ai 状态]');
  const seqOf = (h) => h.states.map((s) => s.state);
  const seqsUp = (h) => h.states.every((s, i) => i === 0 || s.seq > h.states[i - 1].seq);
  const noAdjDup = (h) => h.states.every((s, i) => i === 0 || s.state !== h.states[i - 1].state);
  {
    const h = makeHarness({ asr: { script: ['小助手，今天天气怎么样？'] }, llm: { reply: '今天天气不错，适合出门散步。' } });
    await wait(5);
    check(JSON.stringify(seqOf(h)) === JSON.stringify(['listening']), 'wake:启动即 listening', h.states);
    await speak(h, 'u_alice', 500);
    await untilEv(h, (e) => e.ev === 'turn');
    await wait(5);
    check(JSON.stringify(seqOf(h)) === JSON.stringify(['listening', 'thinking', 'speaking', 'listening']), 'wake 一轮:listening → thinking → speaking → listening', seqOf(h));
    check(seqsUp(h), 'seq 单调递增', h.states.map((s) => s.seq));
    check(h.states.every((s) => s.t === 'state' && Object.keys(s).sort().join() === 'seq,state,t' && Number.isInteger(s.seq)), '帧只含 {t,state,seq},不带正文', h.states);
    // 去重:同样的配置再设一次 / 换声音不发;有人进房 → 重发当前状态(新 seq)
    const n = h.states.length;
    h.agent.setConfig(normalizeAiVoiceConfig({}).config);
    h.agent.setConfig(normalizeAiVoiceConfig({ voice: 'Ethan' }).config);
    await wait(5);
    check(h.states.length === n, '去重:状态不变不发', h.states.slice(n));
    h.agent.republishState();
    await wait(5);
    check(h.states.length === n + 1 && h.states.at(-1).state === 'listening' && h.states.at(-1).seq > h.states[n - 1].seq, '新成员进房:重发当前状态(新 seq)', h.states.at(-1));
    // 热更新触发方式:wake → ptt → idle,ptt → always → listening;重复设 ptt 不再发
    h.agent.setConfig(normalizeAiVoiceConfig({ trigger: 'ptt' }).config);
    h.agent.setConfig(normalizeAiVoiceConfig({ trigger: 'ptt' }).config);
    h.agent.setConfig(normalizeAiVoiceConfig({ trigger: 'always' }).config);
    await wait(5);
    check(JSON.stringify(seqOf(h).slice(n + 1)) === JSON.stringify(['idle', 'listening']), '热更新 trigger:listening ↔ idle', seqOf(h).slice(n + 1));
    await h.agent.close();
  }
  {
    // ptt:平时 idle;@AI 聊天 → thinking → speaking → idle
    const h = makeHarness({ config: { trigger: 'ptt' }, llm: { reply: '一加一等于二。' } });
    await wait(5);
    check(JSON.stringify(seqOf(h)) === JSON.stringify(['idle']), 'ptt:启动即 idle', h.states);
    await speak(h, 'u_alice', 300);
    check(h.states.length === 1, 'ptt:说话不改状态', h.states);
    h.agent.onChat({ senderId: 'u_bob', senderName: 'Bob', body: '@AI 一加一等于几' });
    await untilEv(h, (e) => e.ev === 'turn');
    await wait(5);
    check(JSON.stringify(seqOf(h)) === JSON.stringify(['idle', 'thinking', 'speaking', 'idle']), 'ptt 一轮:idle → thinking → speaking → idle', seqOf(h));
    await h.agent.close();
  }
  {
    // 打断:speaking 中插话 → 回到 listening
    const reply = '好的，我给你讲一个很长很长的故事。从前有座山，山里有座庙，庙里有个老和尚在给小和尚讲故事。讲的是什么呢？';
    const h = makeHarness({ config: { maxReplyChars: 200 }, asr: { script: ['小助手，讲个故事', '等一下'] }, llm: { reply }, tts: { msPerChar: 60 }, paceScale: 1 });
    await speak(h, 'u_alice', 400);
    const t0 = Date.now();
    while (h.frames.length < 40 && Date.now() - t0 < 5000) await wait(10);
    check(h.agent.aiState === 'speaking', '播放中:speaking', h.agent.aiState);
    for (let i = 0; i < 60 && h.cleared === 0; i++) { h.agent.onAudioFrame('u_alice', tone(48000, 10, { freq: 200, amp: 9000 }), 48000, 1); await wait(10); }
    const turn = await untilEv(h, (e) => e.ev === 'turn');
    await wait(5);
    check(turn?.interrupted === true && JSON.stringify(seqOf(h)) === JSON.stringify(['listening', 'thinking', 'speaking', 'listening']), '打断:speaking → listening', { states: seqOf(h), turn });
    check(noAdjDup(h) && seqsUp(h), '打断路径无重复帧、seq 递增', h.states);
    await h.agent.close();
  }
  {
    // 回合中用掉最后的每小时额度:轮内保持 thinking/speaking,结束后 idle(ASR 已停)
    const h = makeHarness({ config: { trigger: 'always', maxTurnsPerHour: 1 }, asr: { script: ['问一下'] }, llm: { reply: '好。' } });
    await speak(h, 'u_alice', 300);
    await untilEv(h, (e) => e.ev === 'turn');
    await wait(5);
    check(JSON.stringify(seqOf(h)) === JSON.stringify(['listening', 'thinking', 'speaking', 'idle']), '每小时上限:结束后 idle', seqOf(h));
    await h.agent.close();
  }
}

// ── LLM 请求体 / CLI ─────────────────────────────────────────────────────
async function miscTests() {
  console.log('\n[LLM 请求体 / CLI / 配置]');
  let body = null;
  const fakeFetch = async (url, init) => {
    body = JSON.parse(init.body);
    const enc = new TextEncoder();
    const lines = ['data: {"choices":[{"delta":{"content":"你"}}]}\n', 'data: {"choices":[{"delta":{"content":"好"}}]}\n\n', 'data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2}}\n', 'data: [DONE]\n'];
    return { ok: true, status: 200, body: (async function* () { for (const l of lines) yield enc.encode(l); })() };
  };
  const llm = new OpenAiCompatLlm({ apiKey: 'test-key-not-real', fetchImpl: fakeFetch });
  const got = [];
  for await (const ev of llm.stream({ messages: [{ role: 'user', content: 'hi' }], model: 'qwen-flash', maxTokens: 99 })) got.push(ev);
  check(body.stream === true && body.stream_options?.include_usage === true && body.max_tokens === 99 && body.enable_thinking === false && body.model === 'qwen-flash', 'LLM 请求体(流式 / usage / 关思考)', body);
  check(got.map((e) => e.delta ?? '').join('') === '你好' && got.some((e) => e.usage?.out === 2), 'SSE 解析');
  const o = parseArgs(['--circle', 'c_x', '--providers', 'mock', '--auth-v2', '--name', '阿福']);
  check(o.circleId === 'c_x' && o.providers === 'mock' && o.authV2 && o.name === '阿福', 'CLI 参数');
  let threw = false;
  try { parseArgs(['--bogus']); } catch { threw = true; }
  check(threw, '未知参数报错');
  const c = loadConfig({ env: { LARES_AI_CONFIG: JSON.stringify({ trigger: 'always', maxReplyChars: 9999 }) }, name: '阿福' });
  check(c.trigger === 'always' && c.maxReplyChars === 400 && c.name === '阿福' && c.voice === AI_VOICE_DEFAULTS.voice, 'LARES_AI_CONFIG + 夹紧 + --name');
  // 子进程:坏参数 → 退出码 2 + stdout JSON
  const r = await new Promise((resolve) => {
    const ch = spawn(process.execPath, [path.join(HERE, '..', 'bots', 'voice-agent', 'index.mjs'), '--providers', 'mock'], { stdio: ['ignore', 'pipe', 'ignore'] });
    let out = '';
    ch.stdout.on('data', (d) => { out += d; });
    ch.on('exit', (code) => resolve({ code, out }));
  });
  const lines = r.out.trim().split('\n').map((l) => { try { return JSON.parse(l); } catch { return null; } });
  check(r.code === 2 && lines.every(Boolean) && lines.at(-1).ev === 'exit' && lines.at(-1).code === 2, '缺 --circle → exit 2,stdout 每行 JSON', r);
}

async function run() {
  chunkerTests();
  wakeTests();
  capsTests();
  historyTests();
  await audioTests();
  await pipelineTests();
  await miscTests();
}
await run();
console.log(T.fail === 0 ? `\n全部通过(${T.pass} 通过)` : `\n${T.pass} 通过,${T.fail} 失败`);
process.exit(T.fail === 0 ? 0 : 1);
