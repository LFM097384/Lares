// DashScope 实时 ASR(qwen3-asr-flash-realtime)与实时 TTS(qwen3-tts-flash-realtime),都走 WebSocket。
// 密钥只放请求头,永不打印。错误日志只记类型/错误码,不记内容。

import crypto from 'node:crypto';
import WebSocket from 'ws';
import { int16ToBase64, base64ToInt16 } from '../audio.mjs';

const HOST = () => process.env.LARES_DASHSCOPE_HOST || 'dashscope.aliyuncs.com';
const eid = () => `event_${crypto.randomBytes(9).toString('hex')}`;
const log = (m) => process.stderr.write(`[ai-voice] ${m}\n`);

function openWs(url, apiKey, timeoutMs = 10000) {
  return new WebSocket(url, { headers: { Authorization: `Bearer ${apiKey}` }, handshakeTimeout: timeoutMs, maxPayload: 64 * 1024 * 1024 });
}

// ── ASR ──────────────────────────────────────────────────────────────────
export const ASR_MODEL = 'qwen3-asr-flash-realtime';
const ASR_CHUNK_BYTES = 3200; // 100ms @ 16k
const ASR_MAX_QUEUED = 80; // 握手期间最多攒 8s

/**
 * 一个说话人一条连接。由 pipeline 的 SpeakerAsr 管理开合:有声才开,空闲 ~20s 关。
 * open() 立即返回句柄;握手完成前送来的音频先排队(保住 pre-roll 和开口第一个字)。
 */
export class DashscopeAsr {
  constructor({ apiKey, model = ASR_MODEL, vadThreshold = 0.2, silenceMs = 800 } = {}) {
    if (!apiKey) throw new Error('dashscope_api_key_missing');
    Object.assign(this, { apiKey, model, vadThreshold, silenceMs });
    this.sessions = 0;
  }

  open({ identity, onPartial, onFinal, onClose, onError }) {
    this.sessions += 1;
    const ws = openWs(`wss://${HOST()}/api-ws/v1/realtime?model=${encodeURIComponent(this.model)}`, this.apiKey);
    const openedAt = Date.now();
    let live = false;
    let closed = false;
    let pending = Buffer.alloc(0);
    const queue = [];
    let samples = 0;
    let finishResolve = null;
    const sendChunk = (buf) => {
      try { ws.send(JSON.stringify({ event_id: eid(), type: 'input_audio_buffer.append', audio: buf.toString('base64') })); } catch { /* 已断 */ }
    };
    const close = () => {
      if (closed) return;
      closed = true;
      try { ws.close(1000); } catch { /* ignore */ }
      finishResolve?.();
      onClose?.();
    };
    ws.on('message', (raw) => {
      let m;
      try { m = JSON.parse(raw.toString()); } catch { return; }
      switch (m.type) {
        case 'session.created':
          ws.send(JSON.stringify({
            event_id: eid(),
            type: 'session.update',
            session: {
              modalities: ['text'],
              input_audio_format: 'pcm',
              sample_rate: 16000,
              input_audio_transcription: {}, // 不给 language:中英混说自动检测最好
              turn_detection: { type: 'server_vad', threshold: this.vadThreshold, silence_duration_ms: this.silenceMs },
            },
          }));
          live = true;
          log(`asr session live in ${Date.now() - openedAt}ms (flushing ${queue.length} queued chunks)`);
          for (const c of queue.splice(0)) sendChunk(c);
          break;
        case 'conversation.item.input_audio_transcription.text':
          onPartial?.(`${m.text ?? ''}${m.stash ?? ''}`, m.item_id);
          break;
        case 'conversation.item.input_audio_transcription.completed':
          onFinal?.(String(m.transcript ?? ''), m.item_id);
          break;
        case 'session.finished':
          close();
          break;
        case 'error':
          log(`asr error ${m.error?.code ?? 'unknown'} (${identity ? 'speaker' : '?'})`);
          onError?.(new Error(`asr_${m.error?.code ?? 'error'}`));
          break;
        default:
      }
    });
    ws.on('error', (e) => { log(`asr socket error: ${e.code ?? e.message}`); onError?.(e); close(); });
    ws.on('close', close);
    return {
      get audioSec() { return samples / 16000; },
      get live() { return live; },
      send(pcm16k) {
        if (closed || !pcm16k.length) return;
        samples += pcm16k.length;
        pending = Buffer.concat([pending, Buffer.from(pcm16k.buffer, pcm16k.byteOffset, pcm16k.byteLength)]);
        while (pending.length >= ASR_CHUNK_BYTES) {
          const c = Buffer.from(pending.subarray(0, ASR_CHUNK_BYTES));
          pending = pending.subarray(ASR_CHUNK_BYTES);
          if (live) sendChunk(c);
          else { queue.push(c); if (queue.length > ASR_MAX_QUEUED) queue.shift(); }
        }
      },
      /// 发掉尾巴 + session.finish,最多等 timeoutMs 再关。
      finish(timeoutMs = 1500) {
        if (closed) return Promise.resolve();
        if (!live) { close(); return Promise.resolve(); }
        if (pending.length) { sendChunk(Buffer.from(pending)); pending = Buffer.alloc(0); }
        return new Promise((resolve) => {
          finishResolve = resolve;
          try { ws.send(JSON.stringify({ event_id: eid(), type: 'session.finish' })); } catch { close(); }
          setTimeout(close, timeoutMs).unref?.();
        });
      },
      close,
    };
  }
}

// ── TTS ──────────────────────────────────────────────────────────────────
export const TTS_MODEL = 'qwen3-tts-flash-realtime';
export const TTS_RATE = 24000;

/**
 * commit 模式:每块 append + commit,服务端按提交顺序逐段返回 response.audio.delta … response.done。
 * 一条连接只允许一次 session.update(在 open 时、关键路径之外做完)。
 * 打断时直接 close(),不复用。
 */
export class DashscopeTts {
  constructor({ apiKey, model = TTS_MODEL, languageType = 'Chinese', openTimeoutMs = 10000 } = {}) {
    if (!apiKey) throw new Error('dashscope_api_key_missing');
    Object.assign(this, { apiKey, model, languageType, openTimeoutMs });
    this.opened = 0;
  }

  open({ voice = 'Cherry' } = {}) {
    return new Promise((resolve, reject) => {
      const ws = openWs(`wss://${HOST()}/api-ws/v1/realtime?model=${encodeURIComponent(this.model)}`, this.apiKey, this.openTimeoutMs);
      let ready = false;
      let dead = false;
      let handlers = {};
      let sent = 0; // 已提交段数
      let done = 0; // 已完成段数(当前在合成的段 = done)
      let finishResolve = null;
      const timer = setTimeout(() => fail(new Error('tts_open_timeout')), this.openTimeoutMs);
      const send = (o) => ws.send(JSON.stringify({ event_id: eid(), ...o }));
      const fail = (e) => {
        if (!ready) { clearTimeout(timer); dead = true; try { ws.terminate(); } catch { /* */ } reject(e); return; }
        handlers.onError?.(e);
        session.close();
      };
      const session = {
        sampleRate: TTS_RATE,
        voice,
        openedAt: Date.now(),
        used: false,
        get alive() { return !dead && ws.readyState === WebSocket.OPEN; },
        setHandlers(h) { handlers = h ?? {}; },
        send(text) {
          session.used = true;
          const idx = sent++;
          send({ type: 'input_text_buffer.append', text });
          send({ type: 'input_text_buffer.commit' });
          return idx;
        },
        finish(timeoutMs = 3000) {
          if (dead) return Promise.resolve();
          return new Promise((r) => {
            finishResolve = r;
            try { send({ type: 'session.finish' }); } catch { session.close(); }
            setTimeout(() => session.close(), timeoutMs).unref?.();
          });
        },
        close() {
          if (dead) return;
          dead = true;
          clearTimeout(timer);
          try { ws.close(1000); } catch { /* */ }
          setTimeout(() => { try { ws.terminate(); } catch { /* */ } }, 1000).unref?.();
          finishResolve?.();
        },
      };
      ws.on('message', (raw) => {
        let m;
        try { m = JSON.parse(raw.toString()); } catch { return; }
        switch (m.type) {
          case 'session.created':
            send({ type: 'session.update', session: { voice, mode: 'commit', language_type: this.languageType, response_format: 'pcm', sample_rate: TTS_RATE } });
            break;
          case 'session.updated':
            if (!ready) { ready = true; clearTimeout(timer); this.opened += 1; resolve(session); }
            break;
          case 'response.audio.delta':
            if (m.delta) handlers.onAudio?.(done, base64ToInt16(m.delta));
            break;
          case 'response.done': {
            const chars = m.response?.usage?.characters ?? m.usage?.characters ?? 0;
            handlers.onSegmentDone?.(done, { characters: chars });
            done += 1;
            break;
          }
          case 'session.finished':
            session.close();
            break;
          case 'error':
            log(`tts error ${m.error?.code ?? 'unknown'}`);
            fail(new Error(`tts_${m.error?.code ?? 'error'}`));
            break;
          default:
        }
      });
      ws.on('error', (e) => fail(e));
      ws.on('close', () => { if (!ready) fail(new Error('tts_closed_before_ready')); else if (!dead) { dead = true; handlers.onError?.(new Error('tts_closed')); finishResolve?.(); } });
    });
  }
}

// 供冒烟测试使用
export const _internal = { int16ToBase64 };
