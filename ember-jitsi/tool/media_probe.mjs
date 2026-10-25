// ember-jitsi · 媒体连通性探针:node ember-jitsi/tool/media_probe.mjs [speech.wav]
// 媒体连通性探针:两个无头 Chromium 进同一房间,报告 ICE 状态与 RTP 字节数
import { JitsiBrowserBridge } from '../bridge.mjs';
const url = process.env.JITSI_URL || 'https://localhost:8443', room = 'mediaprobe' + Date.now() % 10000;
const a = new JitsiBrowserBridge({ url, room, name: 'A', tapAudio: true });
let loud = 0; a.on('audio', (id, pcm) => { let s = 0; for (const v of pcm) s += v * v; if (Math.sqrt(s / pcm.length) > 300) loud++; });
await a.join();
const b = new JitsiBrowserBridge({ url, room, name: 'B', fakeAudioWav: process.argv[2] || null });
await b.join(); await b.addMic();
await new Promise(r => setTimeout(r, 10000));
const rtc = (x) => x.page.evaluate(async () => { const r = []; for (const pc of window.__pcs) { const st = await pc.getStats(); st.forEach(s => { if (s.type === 'inbound-rtp' || s.type === 'outbound-rtp') r.push(`${s.type}:${s.kind}:${s.bytesReceived ?? s.bytesSent}`); }); r.push(`ice=${pc.iceConnectionState}`); } return r.join(' '); });
console.log('A(receiver)', await rtc(a)); console.log('B(sender)', await rtc(b)); console.log('loud frames at A', loud);
await b.leave(); await a.leave();
