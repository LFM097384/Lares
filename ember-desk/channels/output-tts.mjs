// 输出通道 · 朗读。DashScope TTS(有 LARES_DASHSCOPE_API_KEY 时;收 24 kHz PCM → 临时 WAV → Media.SoundPlayer 播放)
// 否则 SAPI(System.Speech,Windows PowerShell 5.1)。文字经 env base64 JSON 传入。
// 缺省不启用(要自己开);但 /speak 不论开没开都能用(speak())。
// 测试注入 ctx.overrides.tts = { run(exe, script, o), dashscope(text) → Int16Array }
import os from 'node:os';
import path from 'node:path';
import { writeFileSync, unlinkSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { runPs, WINPS, PS_DECODE } from '../ps.mjs';

export const SAPI_SCRIPT = [
  '$ErrorActionPreference = "Stop"',
  PS_DECODE,
  'Add-Type -AssemblyName System.Speech',
  '$s = New-Object System.Speech.Synthesis.SpeechSynthesizer',
  'try { $v = $s.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -like "zh*" } | Select-Object -First 1; if ($v) { $s.SelectVoice($v.VoiceInfo.Name) } } catch { }',
  '$s.Speak([string]$p.text)',
  'Write-Output ok',
].join('; ');

export const PLAY_SCRIPT = [
  '$ErrorActionPreference = "Stop"',
  PS_DECODE,
  '(New-Object Media.SoundPlayer ([string]$p.path)).PlaySync()',
  'Write-Output ok',
].join('; ');

export function wavFromPcm16(int16, sampleRate) {
  const data = Buffer.from(int16.buffer, int16.byteOffset, int16.byteLength);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8);
  h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(sampleRate, 24); h.writeUInt32LE(sampleRate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

/// DashScope 实时 TTS:送一段文字,收齐 PCM。返回 {pcm:Int16Array, sampleRate}
export async function dashscopeSynth(text, { apiKey, host, log = () => {}, timeoutMs = 30_000 } = {}) {
  const { loadWs } = await import('../../ember-jitsi/deps.mjs');
  const { DashscopeTts } = await import('../../hearthvoice/providers/dashscope.mjs');
  const tts = new DashscopeTts({ apiKey, host, log, WebSocket: await loadWs() });
  const sess = await tts.open({ voice: 'Cherry' });
  const chunks = [];
  try {
    await new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error('tts_timeout')), timeoutMs);
      sess.setHandlers({
        onAudio: (_seg, pcm) => chunks.push(pcm),
        onSegmentDone: () => { clearTimeout(t); resolve(); },
        onError: (e) => { clearTimeout(t); reject(e); },
      });
      sess.send(text);
    });
  } finally { try { sess.close(); } catch { /* */ } }
  const len = chunks.reduce((n, c) => n + c.length, 0);
  const pcm = new Int16Array(len);
  let o = 0;
  for (const c of chunks) { pcm.set(c, o); o += c.length; }
  return { pcm, sampleRate: sess.sampleRate ?? 24000 };
}

export default function outputTts(ctx) {
  const ov = ctx.overrides?.tts ?? {};
  const run = ov.run ?? ((exe, script, o) => runPs(exe, script, o));
  const synth = ov.dashscope ?? ((text) => dashscopeSynth(text, { apiKey: ctx.secrets.LARES_DASHSCOPE_API_KEY, host: ctx.env?.LARES_DASHSCOPE_HOST, log: (m) => ctx.log?.(`tts: ${m}`) }));
  const platformOk = ov.run ? true : process.platform === 'win32';
  let running = false;
  let busy = Promise.resolve();
  let lastEngine = null;

  async function speakOnce(text) {
    const t = String(text ?? '').slice(0, 1000);
    if (!t.trim()) return { ok: false, engine: 'none', error: 'empty' };
    if (ctx.secrets?.LARES_DASHSCOPE_API_KEY) {
      try {
        const { pcm, sampleRate } = await synth(t);
        if (pcm.length) {
          const f = path.join(os.tmpdir(), `ember-desk-tts-${randomBytes(6).toString('hex')}.wav`);
          writeFileSync(f, wavFromPcm16(pcm, sampleRate));
          try {
            const r = await run(WINPS, PLAY_SCRIPT, { payload: { path: f }, timeoutMs: 120_000 });
            if (r.code === 0) { lastEngine = 'dashscope'; return { ok: true, engine: 'dashscope' }; }
          } finally { try { unlinkSync(f); } catch { /* */ } }
        }
      } catch (e) { ctx.log?.(`tts dashscope failed: ${e.message} → sapi`); }
    }
    if (!platformOk) return { ok: false, engine: 'none', error: '仅 Windows' };
    const r = await run(WINPS, SAPI_SCRIPT, { payload: { text: t }, timeoutMs: 120_000 });
    lastEngine = 'sapi';
    return r.code === 0 ? { ok: true, engine: 'sapi' } : { ok: false, engine: 'sapi', error: `code ${r.code}` };
  }

  /// 串行朗读,不叠音
  const speak = (text) => { const p = busy.then(() => speakOnce(text)); busy = p.catch(() => {}); return p; };

  return {
    id: 'tts',
    kind: 'output',
    name: '朗读',
    describe: () => '把消息读出来(DashScope TTS,或 Windows 自带 SAPI);缺省关闭',
    configured: () => platformOk || Boolean(ctx.secrets?.LARES_DASHSCOPE_API_KEY),
    async start() { running = true; },
    async stop() { running = false; },
    status: () => ({ running, detail: `${ctx.secrets?.LARES_DASHSCOPE_API_KEY ? 'DashScope TTS(失败退回 SAPI)' : 'Windows SAPI'}${lastEngine ? ` · 上次 ${lastEngine}` : ''}` }),
    speak,
    async send(msg) { if (!running) return false; const r = await speak(msg?.speak ?? msg?.text ?? ''); return r.ok; },
  };
}
