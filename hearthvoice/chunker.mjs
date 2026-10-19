// 给 TTS 用的断句:批量(chunkForSpeech)+ 增量(IncrementalChunker)。
// 移植自 v2v-lab/v2vlab/chunker.py(行为一致,测试性质见 test/ai_voice.mjs):
//   * 句界判断只看边界两侧的字符:边界后面已经有字符,它就是终局的。
//     所以「最后一个已定边界」之前的文本(稳定前缀)切出来的块与全文批量切的完全相同。
//   * 增量版唯一不可避免的差别:批量会把过短的尾巴并回上一块;流式时上一块可能已经在播,
//     尾巴只好单独发。拼起来的文本相同。
//   * first_clause:第一块在第一个逗号/句号处(已够 first_min_chars)就发,首字延迟更低。
// 小数(3.14)、版本号(2.5)不会被切:'.;:' 只有后面跟空白才算句界。

const SENTENCE_RE = /(?<=[。！？!?…])|(?<=[.;:])(?=\s)/gu;
const CLAUSE_RE = /(?<=[，,、；])/u;
const ANY_RE = /(?<=[。！？!?…，,、；])|(?<=[.;:])(?=\s)/gu;
const FULLWIDTH_END = /[\u3000-\u303f\uff00-\uffef]$/u;

export const DEFAULT_CHUNKING = Object.freeze({
  first_min_chars: 8,
  min_chars: 24,
  max_chars: 160,
  merge_tail_below: 12,
  first_clause: false,
});

/// 语音机器人用的默认值:短首块(第一个逗号、≥4 字就发),之后的块也偏短(回复本来就短)。
export const VOICE_CHUNKING = Object.freeze({
  first_min_chars: 4,
  min_chars: 12,
  max_chars: 80,
  merge_tail_below: 6,
  first_clause: true,
});

const len = (s) => s.length;
const isBlank = (s) => !s || !s.trim();

function splitZeroWidth(text, re) {
  const out = [];
  let last = 0;
  for (const m of text.matchAll(new RegExp(re.source, 'gu'))) {
    const p = m.index;
    if (p > last) { out.push(text.slice(last, p)); last = p; }
  }
  out.push(text.slice(last));
  return out;
}

function splitLong(piece, maxChars) {
  if (len(piece) <= maxChars) return [piece];
  const out = [];
  let buf = '';
  for (const part of piece.split(CLAUSE_RE)) {
    if (!part) continue;
    if (len(buf) + len(part) > maxChars && buf) { out.push(buf); buf = part; } else buf += part;
  }
  if (buf) out.push(buf);
  const fin = [];
  for (const chunk of out) {
    if (len(chunk) <= maxChars) { fin.push(chunk); continue; }
    // 没有空格的长串(中文无标点):按字硬切
    if (!chunk.includes(' ')) {
      for (let i = 0; i < chunk.length; i += maxChars) fin.push(chunk.slice(i, i + maxChars));
      continue;
    }
    let b = '';
    for (const w of chunk.split(' ')) {
      if (len(b) + len(w) + 1 > maxChars && b) { fin.push(b); b = w; } else b = `${b} ${w}`.trim();
    }
    if (b) fin.push(b);
  }
  return fin;
}

function accumulate(text, c) {
  const raw = splitZeroWidth(text, SENTENCE_RE).filter((p) => p && p.trim());
  const pieces = [];
  for (const p of raw) pieces.push(...splitLong(p, c.max_chars));
  const chunks = [];
  let buf = '';
  for (const piece of pieces) {
    buf = buf ? buf + piece : piece;
    const floor = chunks.length === 0 ? c.first_min_chars : c.min_chars;
    if (len(buf.trim()) >= floor) { chunks.push(buf.trim()); buf = ''; }
  }
  return { chunks, buf };
}

function firstClauseEnd(text, c) {
  for (const m of text.matchAll(ANY_RE)) {
    const pos = m.index;
    if (pos > 0 && pos < text.length && len(text.slice(0, pos).trim()) >= c.first_min_chars) return pos;
  }
  return 0;
}

function stablePrefixEnd(text) {
  let last = 0;
  for (const m of text.matchAll(SENTENCE_RE)) {
    const pos = m.index;
    if (pos > 0 && pos < text.length) last = pos;
  }
  return last;
}

function mergeTail(chunks, below) {
  if (chunks.length > 1 && len(chunks[chunks.length - 1]) < below) {
    const tail = chunks.pop();
    const prev = chunks[chunks.length - 1];
    const joiner = FULLWIDTH_END.test(prev) ? '' : ' ';
    chunks[chunks.length - 1] = (prev + joiner + tail).trim();
  }
  return chunks;
}

export function chunkForSpeech(text, cfg) {
  let c = { ...DEFAULT_CHUNKING, ...(cfg ?? {}) };
  if (isBlank(text)) return [];
  if (c.first_clause) {
    let end = firstClauseEnd(text + ' ', c);
    end = end ? Math.min(end, text.length) : 0;
    const head = end ? text.slice(0, end).trim() : '';
    if (head && !isBlank(text.slice(end))) {
      const rest = chunkForSpeech(text.slice(end), { ...c, first_clause: false, first_min_chars: c.min_chars });
      return [head, ...rest];
    }
    c = { ...c, first_clause: false };
  }
  const { chunks, buf } = accumulate(text, c);
  if (buf.trim()) chunks.push(buf.trim());
  return mergeTail(chunks, c.merge_tail_below);
}

/// 喂 LLM token,拿到已终局的块;流结束调 flush()。
export class IncrementalChunker {
  constructor(cfg) {
    this.cfg = { ...DEFAULT_CHUNKING, ...(cfg ?? {}) };
    this.text = '';
    this.emitted = [];
    this.offset = 0;
    this.headDone = !this.cfg.first_clause;
  }

  _restCfg() {
    return this.cfg.first_clause ? { ...this.cfg, first_clause: false, first_min_chars: this.cfg.min_chars } : this.cfg;
  }

  feed(token) {
    if (!token) return [];
    this.text += token;
    const out = [];
    if (!this.headDone) {
      const end = firstClauseEnd(this.text, this.cfg);
      if (!end) return [];
      this.offset = end;
      this.headDone = true;
      const head = this.text.slice(0, end).trim();
      out.push(head);
      this.emitted.push(head);
    }
    const body = this.text.slice(this.offset);
    const end = stablePrefixEnd(body);
    if (end <= 0) return out;
    const { chunks } = accumulate(body.slice(0, end), this._restCfg());
    const already = this.emitted.length - (this.cfg.first_clause && this.offset ? 1 : 0);
    const more = chunks.slice(already);
    this.emitted.push(...more);
    return out.concat(more);
  }

  flush() {
    let full;
    if (this.cfg.first_clause && this.offset) {
      const body = chunkForSpeech(this.text.slice(this.offset), { ...this._restCfg(), merge_tail_below: 0 });
      full = [this.emitted[0], ...body];
    } else {
      full = chunkForSpeech(this.text, { ...this.cfg, merge_tail_below: 0 });
    }
    const rest = mergeTail(full.slice(this.emitted.length), this.cfg.merge_tail_below);
    this.emitted.push(...rest);
    return rest;
  }
}

// ── 口播清洗:去掉 TTS 不该念出来的东西 ──────────────────────────────────
const SPOKEN_MARKERS = ['gasp', 'laugh', 'laughs', 'sigh', 'sighs', 'whisper', 'breath', 'clears_throat', 'cough',
  'sobs', 'cries', 'gasps', 'sniffles', 'hm', 'hmm', 'chuckle', 'chuckles', 'pauses'];
const MARKER_RE = new RegExp(`\\[(?:${SPOKEN_MARKERS.join('|')})\\]`, 'giu');
const MD_RE = /[*#`_~>|]+/gu;
const EMOJI_RE = /\p{Extended_Pictographic}\uFE0F?/gu;

/// 去掉 [laugh] 这类口播标记、Markdown 符号与 emoji;多余空白压成一个。
export function cleanForSpeech(text) {
  return String(text ?? '')
    .replace(MARKER_RE, '')
    .replace(MD_RE, '')
    .replace(EMOJI_RE, '')
    .replace(/[ \t]{2,}/g, ' ')
    .replace(/\s*\n+\s*/g, ' ')
    .trim();
}
