// 纯音频工具:重采样、能量 VAD、PCM 小工具。无 rtc-node 依赖(单元测试可直接跑)。

export const ROOM_RATE = 48000;
export const FRAME_SAMPLES = 480; // 10ms @ 48k
export const ASR_RATE = 16000;

/// 任意采样率 → 目标采样率(线性插值;降采样前做简单盒式平均防混叠)。返回新的 Int16Array(拷贝)。
export function resample(input, from, to) {
  if (from === to) return Int16Array.from(input);
  if (from % to === 0) {
    const k = from / to;
    const n = Math.floor(input.length / k);
    const out = new Int16Array(n);
    for (let i = 0; i < n; i++) {
      let s = 0;
      for (let j = 0; j < k; j++) s += input[i * k + j];
      out[i] = Math.round(s / k);
    }
    return out;
  }
  const ratio = from / to;
  const n = Math.floor(input.length / ratio);
  const out = new Int16Array(n);
  for (let i = 0; i < n; i++) {
    const x = i * ratio;
    const a = Math.floor(x);
    const b = Math.min(a + 1, input.length - 1);
    const f = x - a;
    out[i] = Math.round(input[a] * (1 - f) + input[b] * f);
  }
  return out;
}

/// 取多声道交织数据的第一声道。
export function firstChannel(data, channels) {
  if (!channels || channels === 1) return data;
  const n = Math.floor(data.length / channels);
  const out = new Int16Array(n);
  for (let i = 0; i < n; i++) out[i] = data[i * channels];
  return out;
}

export function rmsDbfs(pcm) {
  if (!pcm.length) return -100;
  let s = 0;
  for (let i = 0; i < pcm.length; i++) s += pcm[i] * pcm[i];
  const rms = Math.sqrt(s / pcm.length) / 32768;
  return rms <= 1e-7 ? -100 : 20 * Math.log10(rms);
}

export function concatInt16(parts) {
  let n = 0;
  for (const p of parts) n += p.length;
  const out = new Int16Array(n);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

export function int16ToBase64(pcm) {
  return Buffer.from(pcm.buffer, pcm.byteOffset, pcm.byteLength).toString('base64');
}

export function base64ToInt16(b64) {
  const buf = Buffer.from(b64, 'base64');
  const n = Math.floor(buf.length / 2);
  const out = new Int16Array(n);
  for (let i = 0; i < n; i++) out[i] = buf.readInt16LE(i * 2);
  return out;
}

/// 生成测试用 PCM:正弦(带一点包络),或静音。
export function tone(rate, ms, { freq = 220, amp = 8000 } = {}) {
  const n = Math.round((rate * ms) / 1000);
  const out = new Int16Array(n);
  for (let i = 0; i < n; i++) out[i] = Math.round(Math.sin((2 * Math.PI * freq * i) / rate) * amp);
  return out;
}

/**
 * 本地能量 VAD(只看本机算出来的能量,不出网)。
 * 状态:idle → speaking(连续有声 ≥ onsetMs)→ hangover(静音)→ idle(静音 ≥ hangoverMs)。
 * - onset:本帧刚进入 speaking
 * - ended:本帧 hangover 结束(之后不再给 ASR 送音频)
 * - runMs:当前这段「有声」持续了多久(容忍 < gapMs 的短停顿),打断判定用
 * 噪声底自适应:静音帧时缓慢跟踪,阈值 = max(minDb, floor + marginDb)。
 */
export class EnergyVad {
  constructor({ onsetMs = 30, hangoverMs = 1000, gapMs = 150, minDb = -48, marginDb = 12 } = {}) {
    Object.assign(this, { onsetMs, hangoverMs, gapMs, minDb, marginDb });
    this.floor = -60;
    this.state = 'idle';
    this.voicedMs = 0; // 连续有声(用于 onset)
    this.silentMs = 0; // 连续静音
    this.runMs = 0;
  }

  get threshold() { return Math.max(this.minDb, this.floor + this.marginDb); }
  get active() { return this.state !== 'idle'; }

  push(pcm, durMs) {
    const db = rmsDbfs(pcm);
    const voiced = db >= this.threshold;
    let onset = false;
    let ended = false;
    if (voiced) {
      this.voicedMs += durMs;
      this.silentMs = 0;
      this.runMs += durMs;
    } else {
      this.voicedMs = 0;
      this.silentMs += durMs;
      if (this.silentMs >= this.gapMs) this.runMs = 0;
      this.floor = Math.min(-35, Math.max(-80, this.floor * 0.95 + db * 0.05));
    }
    if (this.state === 'idle') {
      if (this.voicedMs >= this.onsetMs) { this.state = 'speaking'; onset = true; }
    } else if (this.state === 'speaking') {
      if (!voiced && this.silentMs >= this.gapMs) this.state = 'hangover';
    } else if (this.state === 'hangover') {
      if (voiced) this.state = 'speaking';
      else if (this.silentMs >= this.hangoverMs) { this.state = 'idle'; ended = true; this.runMs = 0; }
    }
    return { voiced, onset, ended, active: this.active, runMs: this.runMs, db };
  }
}
