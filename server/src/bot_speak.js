// POST /api/v1/speak:服务器代机器人进房说一段话。
//
// 输入是 WAV(PCM16 单声道,任意采样率,≤60 s)。服务器以 identity `bot:<id>` 进 LiveKit 房间,
// 按 WAV 原采样率发布一个 AudioSource,实时节奏推 10 ms 帧,说完取消发布、断开。
//
// @livekit/rtc-node 是原生 FFI 包(约几十 MB),只有用到时才动态加载:
//   1. 服务端自己的依赖(optionalDependencies,装不上不影响信令);
//   2. 退回 server/tool/node_modules(开发机上机器人工具已经装过一份)。
// 都没有 → 501 speak_unavailable。

import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { AccessToken } from 'livekit-server-sdk';

export const WAV_MAX_BYTES = 6 * 1024 * 1024;
export const SPEAK_MAX_SECONDS = 60;

export class WavError extends Error {}

/// 解析 RIFF/WAVE。只收 PCM16 单声道;返回 {sampleRate, samples:Int16Array}。
export function parseWav(buf) {
  const b = Buffer.from(buf);
  if (b.length < 12 || b.toString('ascii', 0, 4) !== 'RIFF' || b.toString('ascii', 8, 12) !== 'WAVE') {
    throw new WavError('not_riff_wave');
  }
  let off = 12;
  let fmt = null;
  let data = null;
  while (off + 8 <= b.length) {
    const id = b.toString('ascii', off, off + 4);
    let size = b.readUInt32LE(off + 4);
    const body = off + 8;
    // 流式写出的 WAV 有时 data 长度写成 0 / 0xFFFFFFFF:按「到文件尾」处理
    if (id === 'data' && (size === 0 || size === 0xffffffff || body + size > b.length)) size = b.length - body;
    if (body + size > b.length) throw new WavError('truncated_chunk');
    if (id === 'fmt ') {
      if (size < 16) throw new WavError('bad_fmt');
      let format = b.readUInt16LE(body);
      if (format === 0xfffe && size >= 40) format = b.readUInt16LE(body + 24); // WAVE_FORMAT_EXTENSIBLE → 子格式 GUID 的前两字节
      fmt = {
        format,
        channels: b.readUInt16LE(body + 2),
        sampleRate: b.readUInt32LE(body + 4),
        blockAlign: b.readUInt16LE(body + 12),
        bits: b.readUInt16LE(body + 14),
      };
    } else if (id === 'data') {
      data = b.subarray(body, body + size);
      if (fmt) break;
    }
    off = body + size + (size & 1); // 块按偶数字节对齐
  }
  if (!fmt) throw new WavError('missing_fmt');
  if (!data) throw new WavError('missing_data');
  if (fmt.format !== 1) throw new WavError('not_pcm');
  if (fmt.bits !== 16) throw new WavError('not_16bit');
  if (fmt.channels !== 1) throw new WavError('not_mono');
  if (fmt.sampleRate < 8000 || fmt.sampleRate > 192000) throw new WavError('bad_sample_rate');
  const n = Math.floor(data.length / 2);
  if (n === 0) throw new WavError('empty');
  if (n / fmt.sampleRate > SPEAK_MAX_SECONDS) throw new WavError('too_long');
  const samples = new Int16Array(n);
  for (let i = 0; i < n; i++) samples[i] = data.readInt16LE(i * 2);
  return { sampleRate: fmt.sampleRate, samples, durationSec: n / fmt.sampleRate };
}

let rtcPromise = null;
/// 返回 rtc-node 模块或 null(不可用)。结果缓存。
export function loadRtcNode() {
  rtcPromise ??= (async () => {
    if (process.env.LARES_DISABLE_RTC_NODE === '1') return null; // 测试用
    try {
      return await import('@livekit/rtc-node');
    } catch { /* 退回 tool 目录 */ }
    try {
      const here = path.dirname(fileURLToPath(import.meta.url));
      const req = createRequire(path.join(here, '..', 'tool', 'package.json'));
      return await import(pathToFileURL(req.resolve('@livekit/rtc-node')).href);
    } catch {
      return null;
    }
  })();
  return rtcPromise;
}

/**
 * 进房、说完、离开。成功 resolve,失败抛错。
 * @param {object} o
 * @param {string} o.url LiveKit ws(s) 地址
 * @param {string} o.apiKey
 * @param {string} o.apiSecret
 * @param {string} o.room 房间名(= circleId)
 * @param {{id:string,name:string}} o.bot
 * @param {{sampleRate:number,samples:Int16Array}} o.wav
 */
export async function speakIntoRoom({ rtc, url, apiKey, apiSecret, room: roomName, bot, wav }) {
  const { Room, AudioSource, LocalAudioTrack, TrackPublishOptions, TrackSource, AudioFrame } = rtc;
  const at = new AccessToken(apiKey, apiSecret, { identity: `bot:${bot.id}`, name: bot.name, ttl: '10m' });
  at.addGrant({ roomJoin: true, room: roomName, canPublish: true, canSubscribe: false, canPublishData: false, hidden: false });
  const jwt = await at.toJwt();

  const room = new Room();
  let source = null;
  let pub = null;
  try {
    await room.connect(url, jwt, { autoSubscribe: false });
    const rate = wav.sampleRate;
    const frameSamples = Math.max(1, Math.round(rate / 100)); // 10 ms
    source = new AudioSource(rate, 1);
    const track = LocalAudioTrack.createAudioTrack('bot-speak', source);
    pub = await room.localParticipant.publishTrack(track, new TrackPublishOptions({ source: TrackSource.SOURCE_MICROPHONE }));
    const start = Date.now();
    let sent = 0;
    while (sent < wav.samples.length) {
      const n = Math.min(frameSamples, wav.samples.length - sent);
      // slice(拷贝)而非 subarray:跨 FFI 的帧不能共用底层 buffer(见 tool/lares_bot.mjs 的长注释)
      let chunk = wav.samples.slice(sent, sent + n);
      if (n < frameSamples) { const pad = new Int16Array(frameSamples); pad.set(chunk); chunk = pad; }
      await source.captureFrame(new AudioFrame(chunk, rate, 1, frameSamples));
      sent += n;
      const lag = Math.round((sent / rate) * 1000) - (Date.now() - start);
      if (lag > 0) await new Promise((r) => setTimeout(r, lag));
    }
    try { await source.waitForPlayout(); } catch { /* 旧版本无此方法也没关系 */ }
    // 尾巴留一点:让最后几帧在网络上走完再取消发布
    await new Promise((r) => setTimeout(r, 200));
  } finally {
    try { if (pub?.sid) await room.localParticipant.unpublishTrack(pub.sid); } catch { /* 断开会一并清理 */ }
    try { await source?.close(); } catch { /* 同上 */ }
    try { await room.disconnect(); } catch { /* 同上 */ }
  }
}
