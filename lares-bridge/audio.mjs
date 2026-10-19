// lares-bridge · 房间音频格式与小工具(与平台本体无关的 PCM 处理留在各 AI 本体里)。
// LiveKit 房间:48 kHz、单声道、10 ms 一帧(480 样本)。入:AudioStream 按此格式交帧;出:AudioSource 按此格式收帧。

export const ROOM_RATE = 48000;
export const FRAME_SAMPLES = 480;

/// 入:多声道交织 Int16 取第一声道(AudioStream 指定了 numChannels:1,通常原样返回)
export function monoOf(data, channels = 1) {
  if (!channels || channels === 1) return data;
  const out = new Int16Array(Math.floor(data.length / channels));
  for (let i = 0; i < out.length; i++) out[i] = data[i * channels];
  return out;
}

/// 出:把任意长度的 48k 单声道 PCM 切成 480 样本一帧;不足一帧的尾巴补零。每帧是独立拷贝(slice,不是 subarray)。
export function framesOf(pcm) {
  const out = [];
  for (let i = 0; i < pcm.length; i += FRAME_SAMPLES) {
    const f = new Int16Array(FRAME_SAMPLES);
    f.set(pcm.subarray(i, Math.min(i + FRAME_SAMPLES, pcm.length)));
    out.push(f);
  }
  return out;
}
