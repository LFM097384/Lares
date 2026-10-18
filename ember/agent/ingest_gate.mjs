// 隐名之约 v2 · 入口脱敏 IngestGate(AGENT-V2.md §5)。
//
//   ASR 原话 utt {speakerId, text}
//     → L0 结构清洗(去说话人字段 / 时间戳 / 语气填充,切句)
//     → L1 PII + 名单(LiveKit 名字 + aliases)   → L2 机构
//     → speakerId → 会话假名 P1、P2…(映射只在本闭包里)
//     → 公共知识保留(L1/L2 allowPublicFacts)
//     → 待改写缓冲(只存 L0–L2 之后的文本;原话在 utterance() 返回前就丢了)
//     → 每 ~20 s 或 ~600 字一批 L3 改写(中性化语气、去自指),写进 ledger;缓冲**立即清空**,最长 60 s
//
// ledger 只在内存里。skill / LLM 只能拿到 ledgerView()(只读访问器,没有原话、没有假名映射、没有名单)。
import { randomUUID } from 'node:crypto';
import { splitSegments } from '../core/gate/l0.mjs';
import { redactPII } from '../core/gate/l1.mjs';
import { redactAffiliation } from '../core/gate/l2.mjs';
import { hasToneMarker, mockRewriteSegment, claimKind } from '../core/gate/l3.mjs';
import { chatJSON } from '../core/gate/llm.mjs';

export const BATCH_MS = 20_000;
export const BATCH_CHARS = 600;
export const MAX_HOLD_MS = 60_000;
const KINDS = new Set(['idea', 'decision', 'todo', 'fact', 'question']);
const PSEUDO_RE = /\bP\d+\b/g;

export const INGEST_L3_PROMPT = `You rewrite lines of a live, anonymised meeting into a neutral running ledger. Each input line is "<pseudonym>: <text>" where the pseudonym (P1, P2, …) is the only speaker label; names and PII are already replaced by placeholders like [参与者] / a participant.
For each meaningful line output ONE entry in the line's language:
- start the text with the pseudonym and a neutral reporting verb ("P2 认为……", "P1 提议……", "P3 questioned whether …");
- remove self-reference (我 / 我们 / my team / our …) and anything revealing the speaker's role, organisation, life facts or ownership of resources;
- neutralise tone: sarcasm, irony, mock enthusiasm, rhetorical questions, catchphrases, dialect → a plain propositional statement keeping stance DIRECTION (support / doubt / oppose) and STRENGTH; never echo the sarcastic phrase;
- keep public world facts verbatim (a well-known book and its author, public figures' public acts, laws, published reports) and flag them "public-fact";
- never copy more than 20 consecutive characters from the input; drop pure filler / greetings;
- kind: idea | decision | todo | fact | question; topic: 2–6 words naming the subject (no people).
Output only JSON: {"entries":[{"p":"P2","text":"...","kind":"idea","topic":"...","flags":["public-fact"|"tone-neutralised"]}]}`;

/** roster: () => [{id, name, aliases?}] — 只在本地用于 L1/L2(LLM 永远看不到) */
export function createIngestGate({
  llm = null, roster = () => [], batchMs = BATCH_MS, batchChars = BATCH_CHARS, maxHoldMs = MAX_HOLD_MS,
  clock = () => Date.now(), setTimer = setTimeout, clearTimer = clearTimeout, log = () => {}, onLedger = () => {}, stats = {},
} = {}) {
  const pseudo = new Map(); // speakerId → 'P<n>'(只在这里)
  let pending = []; // [{p, text, at}] —— L0–L2 之后的文本;L3 完成即清空
  let pendingChars = 0;
  let firstAt = 0;
  let timer = null;
  let flushing = null;
  let closed = false;
  const ledger = []; // [{id, at, p, text, kind, topic, flags}]
  const metrics = { utterances: 0, droppedUnacked: 0, batches: 0, entries: 0, l3Failures: 0, maxHeldMs: 0 };
  const rosterArr = () => { try { return (typeof roster === 'function' ? roster() : roster) || []; } catch { return []; } };

  const pseudonymOf = (speakerId) => {
    let p = pseudo.get(speakerId);
    if (!p) { p = `P${pseudo.size + 1}`; pseudo.set(speakerId, p); }
    return p;
  };

  // L0:时间戳 / 说话人前缀 / 括号注记去掉,切句
  function l0(text) {
    let s = String(text ?? '').replace(/\r?\n+/g, ' ');
    s = s.replace(/\[?\b\d{1,2}:\d{2}(?::\d{2})?\]?/g, ' ').replace(/^\s*[^:：\s]{1,16}[:：]\s*/, '');
    return splitSegments(s.replace(/\s{2,}/g, ' ').trim());
  }
  const scrub = (s, r) => redactAffiliation(redactPII(s, r, { allowPublicFacts: true }), r, { allowPublicFacts: true });

  function arm() {
    if (timer || closed) return;
    timer = setTimer(() => { timer = null; void flush('timer'); }, batchMs);
    timer?.unref?.();
  }

  /// 一句定稿。原话 text 只活在这次调用里:返回后没有任何引用留下。
  function utterance(speakerId, text) {
    if (closed || !speakerId) return 0;
    const r = rosterArr();
    const segs = l0(text);
    if (!segs.length) return 0;
    metrics.utterances += 1;
    const p = pseudonymOf(String(speakerId));
    const now = clock();
    if (!pending.length) firstAt = now;
    let n = 0;
    for (const seg of segs) {
      const clean = scrub(seg, r).replace(PSEUDO_RE, 'P?'); // 有人自称「P3」也不能冒用假名
      if (!clean.replace(/[\s\p{P}]/gu, '')) continue;
      pending.push({ p, text: clean, at: now });
      pendingChars += clean.length;
      n += 1;
    }
    if (pendingChars >= batchChars || now - firstAt >= maxHoldMs) void flush('size');
    else arm();
    return n;
  }

  async function rewriteBatch(batch) {
    if (!llm) {
      return batch.map((b) => {
        const tone = hasToneMarker(b.text);
        const body = mockRewriteSegment(b.text);
        if (!body || !body.replace(/[\s。.；;]/g, '')) return null;
        const flags = tone ? ['tone-neutralised'] : [];
        const zh = /[\u3400-\u9fff]/.test(body);
        return { p: b.p, text: `${b.p} ${zh ? '提到：' : 'said: '}${body}`, kind: claimKind(body, flags), topic: '', flags };
      }).filter(Boolean);
    }
    const user = `LINES:\n${batch.map((b) => `${b.p}: ${b.text}`).join('\n')}\n\nReturn the JSON entries now.`;
    const { data } = await chatJSON(llm, [{ role: 'system', content: INGEST_L3_PROMPT }, { role: 'user', content: user }], { stats, temperature: 0.2 });
    const valid = new Set(batch.map((b) => b.p));
    return (Array.isArray(data?.entries) ? data.entries : []).map((e) => {
      const text = String(e?.text ?? '').trim();
      if (!text) return null;
      const p = valid.has(String(e?.p)) ? String(e.p) : null;
      const flags = (Array.isArray(e?.flags) ? e.flags : []).map(String).filter((f) => f === 'public-fact' || f === 'tone-neutralised');
      return { p, text, kind: KINDS.has(e?.kind) ? e.kind : claimKind(text, flags), topic: String(e?.topic ?? '').slice(0, 60), flags };
    }).filter(Boolean);
  }

  /// L3 一批。缓冲在调用 L3 **之前**就摘下并清空(进行中的那一批只在这个栈帧里),L3 失败也不保留。
  function flush(why = 'manual') {
    if (timer) { clearTimer(timer); timer = null; }
    if (flushing) return flushing.then(() => (pending.length ? flush(why) : undefined));
    if (!pending.length) return Promise.resolve();
    let batch = pending;
    const held = clock() - firstAt;
    metrics.maxHeldMs = Math.max(metrics.maxHeldMs, held);
    pending = [];
    pendingChars = 0;
    firstAt = 0;
    flushing = (async () => {
      try {
        const out = await rewriteBatch(batch);
        const r = rosterArr();
        const at = clock();
        const added = [];
        for (const e of out) {
          // L3 输出再过一遍 L1/L2(LLM 可能写回名字);未知假名一律去掉
          let text = scrub(e.text, r).replace(PSEUDO_RE, (m) => (pseudoValues().has(m) ? m : '某参与者'));
          text = text.replace(/\s{2,}/g, ' ').trim();
          if (!text) continue;
          const entry = Object.freeze({ id: randomUUID(), at, p: e.p, text, kind: e.kind, topic: scrub(e.topic || '', r), flags: Object.freeze([...e.flags]) });
          ledger.push(entry);
          added.push(entry);
        }
        metrics.batches += 1;
        metrics.entries += added.length;
        if (added.length) { try { onLedger(added.length); } catch { /* */ } }
      } catch (e) {
        metrics.l3Failures += 1;
        log(`L3 批次失败(${why}),该批丢弃: ${e?.message ?? e}`); // fail closed:未改写的不进 ledger
      } finally {
        for (const b of batch) b.text = '';
        batch.length = 0;
        batch = null;
        flushing = null;
      }
    })();
    return flushing;
  }
  const pseudoValues = () => new Set(pseudo.values());

  /// 给 skill 的只读访问器:只有 ledger 文本(带假名),拿不到原话、映射、名单
  const view = Object.freeze({
    entries: ({ since = 0 } = {}) => ledger.filter((e) => e.at >= since).map((e) => ({ id: e.id, at: e.at, p: e.p, text: e.text, kind: e.kind, topic: e.topic, flags: [...e.flags] })),
    text: ({ maxChars = 12000 } = {}) => {
      const lines = ledger.map((e) => `- ${e.topic ? `[${e.topic}] ` : ''}${e.text}`);
      let out = lines.join('\n');
      if (out.length > maxChars) out = out.slice(out.length - maxChars);
      return out;
    },
    get size() { return ledger.length; },
  });

  function forget(speakerId) { /* 假名保留(同场重进还是同一个 P),ack 状态在 agent 里清 */ void speakerId; }

  /// 散会:全部清掉
  function wipe() {
    closed = true;
    if (timer) { clearTimer(timer); timer = null; }
    for (const b of pending) b.text = '';
    pending = [];
    pendingChars = 0;
    ledger.length = 0;
    pseudo.clear();
  }

  return {
    utterance,
    flush,
    wipe,
    forget,
    ledgerView: () => view,
    pseudonymCount: () => pseudo.size,
    metrics: () => ({ ...metrics, pending: pending.length, ledger: ledger.length }),
    /// 测试钩子:缓冲快照(只读副本)
    _pending: () => pending.map((b) => ({ ...b })),
    _pendingAgeMs: () => (pending.length ? clock() - firstAt : 0),
  };
}

/// 出门前去掉假名(纪要不带说话人)
export function stripPseudonyms(s) {
  return String(s ?? '')
    .replace(/\bP\d+\s*(?:和|与|及|、|,|，|and)\s*P\d+\s*/g, '有参与者')
    .replace(/(^|[^A-Za-z])P\d+\s*(认为|提议|提出|表示|指出|质疑|建议|同意|反对|提到|说|补充|担心|希望|问)/g, '$1有观点$2')
    .replace(/\bP\d+\s+said[:：]?\s*/gi, '')
    .replace(/\bP\d+\s+(argued|suggested|proposed|questioned|asked|noted)\b/gi, (_, v) => `It was ${v.toLowerCase()}`)
    .replace(/\bP\d+\s+(agreed|disagreed)\b/gi, (_, v) => `Some participants ${v.toLowerCase()}`)
    .replace(/(^|[^A-Za-z])P\d+(?![A-Za-z0-9])/g, (_, pre) => `${pre}${/[\u3400-\u9fff]/.test(pre) || pre === '' ? '有参与者' : 'a participant'}`)
    .replace(/有观点(提到|说)[:：]?\s*/g, '')
    .trim();
}
