// 说话机器人:通过信令服务拿 token,进 LiveKit 房间发布正弦波音频,
// 用于验证「正在说话」指示的端到端链路。
// 用法:node tool/speak_bot.mjs [circleId] [seconds]
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

// 1) 从信令服务拿 token(与真实客户端同协议)。
// 注意:信令连接必须保持到发布结束——presence 就是这条连接,
// 断了机器人就退出成员列表,说话指示也不会显示。
function connectSignaling() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(SIGNALING);
    const userId = 'u_bot';
    ws.on('open', () => {
      ws.send(JSON.stringify({ t: 'hello', userId, deviceId: 'd_bot', name: '机器人', platform: 'bot' }));
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
console.log('[bot] token ok, connecting', url);

// 2) 进房并发布正弦波(440Hz,足够触发 active-speaker)
const room = new Room();
await room.connect(url, token);
console.log('[bot] in room');

const SAMPLE_RATE = 48000;
const CHANNELS = 1;
const source = new AudioSource(SAMPLE_RATE, CHANNELS);
const track = LocalAudioTrack.createAudioTrack('bot-voice', source);
await room.localParticipant.publishTrack(
  track,
  new TrackPublishOptions({ source: TrackSource.SOURCE_MICROPHONE }),
);
console.log('[bot] publishing sine wave for', seconds, 's');

// 10ms 帧:480 samples
const FRAME_SAMPLES = 480;
const frames = (seconds * 1000) / 10;
for (let f = 0; f < frames; f++) {
  const data = new Int16Array(FRAME_SAMPLES);
  for (let i = 0; i < FRAME_SAMPLES; i++) {
    const t = (f * FRAME_SAMPLES + i) / SAMPLE_RATE;
    data[i] = Math.round(Math.sin(2 * Math.PI * 440 * t) * 12000);
  }
  await source.captureFrame(new AudioFrame(data, SAMPLE_RATE, CHANNELS, FRAME_SAMPLES));
  await new Promise((r) => setTimeout(r, 9));
}

await room.disconnect();
signaling.close();
console.log('[bot] done');
process.exit(0);
