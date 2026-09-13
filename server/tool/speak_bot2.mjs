// SPIKE ONLY — second speaking bot, distinct identity + 880 Hz tone.
// Copy of speak_bot.mjs with userId/deviceId/name/frequency changed so that two
// bots can coexist in presence (presence is keyed by userId).
// 用法: node tool/spike_bot2.mjs [circleId] [seconds]
import WebSocket from 'ws';
import {
  Room,
  AudioSource,
  LocalAudioTrack,
  TrackPublishOptions,
  TrackSource,
  AudioFrame,
} from '@livekit/rtc-node';

const circleId = process.argv[2] ?? 'home';
const seconds = Number(process.argv[3] ?? 20);
const SIGNALING = process.env.LARES_SIGNALING ?? 'ws://127.0.0.1:8787';
const TONE_HZ = 880;

function connectSignaling() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(SIGNALING);
    const userId = 'u_bot2';
    ws.on('open', () => {
      ws.send(JSON.stringify({ t: 'hello', userId, deviceId: 'd_bot2', name: '机器人2', platform: 'bot' }));
      setTimeout(() => ws.send(JSON.stringify({ t: 'join', circleId })), 300);
    });
    ws.on('message', (raw) => {
      const msg = JSON.parse(raw);
      if (msg.t === 'token') resolve({ ws, msg });
    });
    ws.on('error', reject);
    setTimeout(() => reject(new Error('token timeout')), 5000);
  });
}

const { ws: signaling, msg: tokenMsg } = await connectSignaling();
const { url, token } = tokenMsg;
console.log('[bot2] token ok, connecting', url);

const room = new Room();
await room.connect(url, token);
console.log('[bot2] in room');

const SAMPLE_RATE = 48000;
const CHANNELS = 1;
const source = new AudioSource(SAMPLE_RATE, CHANNELS);
const track = LocalAudioTrack.createAudioTrack('bot2-voice', source);
await room.localParticipant.publishTrack(
  track,
  new TrackPublishOptions({ source: TrackSource.SOURCE_MICROPHONE }),
);
console.log('[bot2] publishing', TONE_HZ, 'Hz sine wave for', seconds, 's');

const FRAME_SAMPLES = 480;
const frames = (seconds * 1000) / 10;
for (let f = 0; f < frames; f++) {
  const data = new Int16Array(FRAME_SAMPLES);
  for (let i = 0; i < FRAME_SAMPLES; i++) {
    const t = (f * FRAME_SAMPLES + i) / SAMPLE_RATE;
    data[i] = Math.round(Math.sin(2 * Math.PI * TONE_HZ * t) * 12000);
  }
  await source.captureFrame(new AudioFrame(data, SAMPLE_RATE, CHANNELS, FRAME_SAMPLES));
  await new Promise((r) => setTimeout(r, 9));
}

await room.disconnect();
signaling.close();
console.log('[bot2] done');
process.exit(0);
