// Bot 自检:两个 bot 进同一个圈,A 发已知频率的正弦波,B 听并测出频率。
//
// 这验证的是**整条回路**:认证 → 进房 → 发布 → 订阅 → 收帧 → 解码。
// 只验证"能连上"是不够的 —— 此前踩过的坑是连接一切正常、
// 却一帧音频都收不到,而且**没有任何报错**。
//
// 用法:
//   node tool/bot_selftest.mjs [circleId]
// 环境变量:
//   LARES_SIGNALING          信令地址(默认 ws://127.0.0.1:8787)
//   LARES_CIRCLE_PASSCODE    圈口令(服务端开了 circle 鉴权时需要)
//   LARES_AUTH_TOKEN         全局令牌(token 鉴权时需要)

import Pitchfinder from 'pitchfinder';
import { LaresBot, sineWave, SAMPLE_RATE } from './lares_bot.mjs';

const circleId = process.argv[2] ?? 'home';
const TEST_FREQ = 440;
const SECONDS = 3;

/// 测频:用 pitchfinder 的 YIN 算法。
///
/// 为什么不自己写过零法 —— 这是实测的教训:
/// 手写过零法在 220Hz 和 880Hz 上都准(误差 1-2%),**唯独 440Hz 偏差 14%**。
/// 原因是 Opus 编码残留的低频噪声让接近零点的采样反复穿越,
/// 而这个效应恰好在某些频率上被放大。等比例偏移可以校正,
/// 这种**只在特定频率失准**的情况说明算法本身不稳,不该修修补补。
/// YIN 基于自相关,对带噪信号稳健得多,是成熟实现,没必要重造。
function estimateFreq(samples, sampleRate) {
  // 先框出有声区间:静音段会让 YIN 返回 null,拉低有效样本数。
  const threshold = 32768 * 0.02;
  let start = 0;
  while (start < samples.length && Math.abs(samples[start]) < threshold) start++;
  let end = samples.length - 1;
  while (end > start && Math.abs(samples[end]) < threshold) end--;
  if (end - start < sampleRate * 0.1) return 0; // 有声段不足 100ms,没法测

  // YIN 要 Float32 且归一化到 [-1, 1]
  const voiced = samples.subarray(start, end + 1);
  const f32 = new Float32Array(voiced.length);
  for (let i = 0; i < voiced.length; i++) f32[i] = voiced[i] / 32768;

  const detect = Pitchfinder.YIN({ sampleRate });
  // 分窗多次检测取中位数:单窗可能碰上瞬态,中位数能滤掉离群值
  const windowSize = 2048;
  const results = [];
  for (let i = 0; i + windowSize <= f32.length; i += windowSize) {
    const p = detect(f32.subarray(i, i + windowSize));
    if (p && Number.isFinite(p)) results.push(p);
  }
  if (results.length === 0) return 0;
  results.sort((a, b) => a - b);
  return results[Math.floor(results.length / 2)];
}

function rms(samples) {
  let sum = 0;
  for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i];
  return Math.sqrt(sum / samples.length);
}

const shared = {
  circleId,
  signaling: process.env.LARES_SIGNALING,
  passcode: process.env.LARES_CIRCLE_PASSCODE,
  token: process.env.LARES_AUTH_TOKEN,
};

console.log(`[selftest] 圈子=${circleId} 信令=${shared.signaling ?? 'ws://127.0.0.1:8787'}`);

// ── 听众先进房 ──────────────────────────────────────────
// 顺序很重要:听众必须先在房里,否则可能错过说话者的 TrackPublished。
const collected = [];
const speakers = new Set();

const listener = new LaresBot({ ...shared, name: '听众', userId: 'u_bot_listener' });
listener.onAudio((frame, from) => {
  speakers.add(from);
  // frame.data 是 Int16Array
  collected.push(...frame.data);
});

await listener.join();
console.log('[selftest] 听众已进房');

// ── 说话者进房并发声 ────────────────────────────────────
const speaker = new LaresBot({ ...shared, name: '说话者', userId: 'u_bot_speaker' });
await speaker.join();
console.log('[selftest] 说话者已进房,开始发 %dHz 正弦波 %ds', TEST_FREQ, SECONDS);

await speaker.speak(sineWave(TEST_FREQ, SECONDS));
console.log('[selftest] 发送完毕');

// 多等一会儿:网络抖动 + 抖动缓冲会让尾巴晚到
await new Promise((r) => setTimeout(r, 1500));

await speaker.leave();
await listener.leave();

// ── 判定 ────────────────────────────────────────────────
console.log('');
console.log('── 结果 ──');
console.log('收到的说话者:', [...speakers].join(', ') || '(无)');
console.log('累计采样数  :', collected.length);

let ok = true;
if (collected.length === 0) {
  console.error('✗ 一帧音频都没收到 —— 订阅链路没通');
  ok = false;
} else {
  const arr = Int16Array.from(collected);
  const energy = rms(arr);
  const freq = estimateFreq(arr, SAMPLE_RATE);
  const nonZero = arr.reduce((n, v) => n + (v !== 0 ? 1 : 0), 0);

  console.log('时长(秒)   :', (arr.length / SAMPLE_RATE).toFixed(2));
  console.log('RMS 能量    :', energy.toFixed(0));
  console.log('非零采样占比:', ((nonZero / arr.length) * 100).toFixed(1) + '%');
  console.log('测得频率    :', freq.toFixed(1) + 'Hz', `(发的是 ${TEST_FREQ}Hz)`);

  // 容差 ±8%:Opus 是有损编码,加上过零法本身的量化误差
  const drift = Math.abs(freq - TEST_FREQ) / TEST_FREQ;
  if (energy < 100) {
    console.error('✗ 收到的基本是静音 —— 可能订阅到了但没解码');
    ok = false;
  } else if (drift > 0.08) {
    console.error(`✗ 频率偏差 ${(drift * 100).toFixed(1)}% 过大`);
    ok = false;
  } else {
    console.log(`✓ 频率吻合(偏差 ${(drift * 100).toFixed(1)}%)`);
  }
}

console.log(ok ? '\n✓ 自检通过:认证/进房/发布/订阅/收帧 全链路可用' : '\n✗ 自检失败');
process.exit(ok ? 0 : 1);
