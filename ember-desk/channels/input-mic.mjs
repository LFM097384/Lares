// 输入通道 · 口述笔记(个人面):ffmpeg 从 dshow 麦克风取 16 kHz 单声道 s16le → DashScope 实时 ASR,
// 每句定稿追加到 notes/YYYY-MM-DD.md,并进消息流(kind 'note';这是用户自己的笔记,只在本机)。绝不送进会议。
// 日志只记元数据(字数)。
// 降级:没 ffmpeg → configured=false;没 DashScope key → configured=false;找不到麦克风 → detail 说明。
// 测试注入 ctx.overrides.mic = { spawn, listDevices() → string[], asr:{open()}, ffmpegOk:bool, now() }
import path from 'node:path';
import { spawn as nodeSpawn, spawnSync } from 'node:child_process';
import { appendFileSync, mkdirSync } from 'node:fs';
import { files } from '../paths.mjs';

export function parseDshowAudio(stderr) {
  const out = [];
  for (const l of String(stderr).split(/\r?\n/)) {
    const m = l.match(/\]\s+"([^"]+)"\s+\(audio\)/);
    if (m) out.push(m[1]);
  }
  return out;
}

function listDevicesReal() {
  try {
    const r = spawnSync('ffmpeg', ['-hide_banner', '-list_devices', 'true', '-f', 'dshow', '-i', 'dummy'], { windowsHide: true, encoding: 'utf8', timeout: 10_000 });
    return parseDshowAudio(`${r.stderr ?? ''}${r.stdout ?? ''}`);
  } catch { return []; }
}

function ffmpegPresent() {
  try { const r = spawnSync('ffmpeg', ['-hide_banner', '-version'], { windowsHide: true, stdio: 'ignore', timeout: 10_000 }); return r.status === 0; } catch { return false; }
}

const pad = (n) => String(n).padStart(2, '0');
export const dayFile = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}.md`;

export default function inputMic(ctx) {
  const ov = ctx.overrides?.mic ?? {};
  const spawn = ov.spawn ?? nodeSpawn;
  const now = ov.now ?? (() => new Date());
  let ffOk = ov.ffmpegOk;
  const hasFfmpeg = () => (ffOk ??= ffmpegPresent());
  const hasKey = () => Boolean(ov.asr || ctx.secrets?.LARES_DASHSCOPE_API_KEY);
  let devices = null;
  const listDevices = () => (devices ??= (ov.listDevices ?? listDevicesReal)());
  let ff = null;
  let asrSess = null;
  let device = null;
  let notes = 0;
  let lastError = null;

  async function makeAsr() {
    if (ov.asr) return ov.asr;
    const { loadWs } = await import('../../ember-jitsi/deps.mjs');
    const { DashscopeAsr } = await import('../../hearthvoice/providers/dashscope.mjs');
    return new DashscopeAsr({ apiKey: ctx.secrets.LARES_DASHSCOPE_API_KEY, host: ctx.env?.LARES_DASHSCOPE_HOST, log: (m) => ctx.log?.(`mic asr: ${m}`), WebSocket: await loadWs() });
  }

  function onFinal(text) {
    const t = String(text ?? '').trim();
    if (!t) return;
    const d = now();
    const dir = files(ctx.stateDir).notes;
    mkdirSync(dir, { recursive: true });
    appendFileSync(path.join(dir, dayFile(d)), `- ${pad(d.getHours())}:${pad(d.getMinutes())} ${t}\n`);
    notes++;
    ctx.log?.(`mic note appended chars=${t.length}`);
    ctx.emit?.({ kind: 'note', title: '口述笔记', text: t }, { outputs: false });
  }

  const ch = {
    id: 'mic',
    kind: 'input',
    name: '口述笔记',
    describe: () => '麦克风口述 → 语音识别 → 本机笔记(notes/日期.md);个人面,只在本机,不进会议',
    configured: () => hasFfmpeg() && hasKey(),
    async start() {
      if (ff) return;
      if (!hasFfmpeg()) throw Object.assign(new Error('找不到 ffmpeg(需要在 PATH 上)'), { status: 400 });
      if (!hasKey()) throw Object.assign(new Error('缺少 LARES_DASHSCOPE_API_KEY(语音识别)'), { status: 400 });
      device = ctx.config().micDevice || listDevices()[0] || null;
      if (!device) throw Object.assign(new Error('找不到麦克风设备(ffmpeg dshow 列不出音频设备)'), { status: 400 });
      const asr = await makeAsr();
      asrSess = asr.open({ identity: 'desk-mic', onFinal, onError: (e) => { lastError = String(e?.code ?? e?.message ?? e).slice(0, 80); } });
      const proc = spawn('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-f', 'dshow', '-i', `audio=${device}`, '-ac', '1', '-ar', '16000', '-f', 's16le', '-'], { windowsHide: true, stdio: ['pipe', 'pipe', 'ignore'] });
      ff = proc;
      let rest = Buffer.alloc(0);
      proc.stdout.on('data', (d) => {
        const buf = rest.length ? Buffer.concat([rest, d]) : d;
        const even = buf.length - (buf.length % 2);
        rest = buf.subarray(even);
        if (!even) return;
        const copy = Buffer.from(buf.subarray(0, even));
        try { asrSess?.send(new Int16Array(copy.buffer, copy.byteOffset, even / 2)); } catch { /* */ }
      });
      proc.stdin?.on('error', () => {});
      proc.on('error', (e) => { lastError = `ffmpeg: ${e.message}`.slice(0, 80); });
      proc.on('exit', (code) => {
        if (ff === proc) { ff = null; lastError = lastError ?? (code ? `ffmpeg exit ${code}` : null); const s = asrSess; asrSess = null; Promise.resolve(s?.finish?.()).catch(() => {}).finally(() => { try { s?.close?.(); } catch { /* */ } }); ctx.changed?.(ch); }
      });
      ctx.log?.('mic started');
    },
    async stop() {
      const proc = ff;
      if (!proc) return;
      await new Promise((resolve) => {
        const t = setTimeout(() => { try { proc.kill(); } catch { /* */ } }, 2000);
        t.unref?.();
        proc.once('exit', () => { clearTimeout(t); resolve(); });
        try { proc.stdin.write('q'); proc.stdin.end(); } catch { try { proc.kill(); } catch { /* */ } }
      });
      ff = null;
      const s = asrSess;
      asrSess = null;
      try { await s?.finish?.(); } catch { /* */ }
      try { s?.close?.(); } catch { /* */ }
      ctx.log?.(`mic stopped notes=${notes}`);
    },
    status() {
      let detail;
      if (!hasFfmpeg()) detail = '找不到 ffmpeg';
      else if (!hasKey()) detail = '缺少 LARES_DASHSCOPE_API_KEY';
      else if (ff) detail = `录音中:${device} · 本次 ${notes} 句`;
      else detail = `就绪(${ctx.config().micDevice || listDevices()[0] || '无麦克风设备'})${lastError ? ` · 上次错误 ${lastError}` : ''}`;
      return { running: Boolean(ff), detail };
    },
  };
  return ch;
}
