// 隐名之约 v2 · 逐说话人 ASR(任意 ASR provider + 本地能量 VAD;与平台无关)。
// 只有 agent 判定「已 ack」的说话人才会被调用到 push();未 ack 的音频在上一层就丢了(不进 VAD、不送 ASR)。
// 本地 VAD 判有声才开连接;pre-roll 300 ms;空闲 20 s 关连接;握手失败最多重试 2 次。
import { EnergyVad, resample, firstChannel, ASR_RATE } from './audio.mjs';

export class SpeakerAsr {
  constructor({ asr, identity, onFinal, log = () => {}, prerollMs = 300, idleMs = 20_000, retries = 2, hangoverMs = 1000 }) {
    Object.assign(this, { asr, identity, onFinal, log, prerollMs, idleMs, retries });
    this.vad = new EnergyVad({ hangoverMs });
    this.preroll = [];
    this.prerollSamples = 0;
    this.session = null;
    this.idleTimer = null;
    this.attempt = 0;
    this.closed = false;
    this.audioSec = 0;
  }

  /// 房间原始帧(任意采样率 / 声道)
  pushFrame(data, sampleRate, channels) {
    const mono = firstChannel(data, channels);
    const pcm = resample(mono, sampleRate, ASR_RATE);
    this.push(pcm, (pcm.length / ASR_RATE) * 1000);
  }

  push(pcm16k, durMs) {
    if (this.closed) return;
    const v = this.vad.push(pcm16k, durMs);
    if (v.active || v.ended) {
      if (!this.session) this._open();
      for (const p of this.preroll) this.session?.send(p);
      this.preroll = [];
      this.prerollSamples = 0;
      this.session?.send(pcm16k);
      this._armIdle();
    } else {
      this.preroll.push(pcm16k);
      this.prerollSamples += pcm16k.length;
      const max = (ASR_RATE * this.prerollMs) / 1000;
      while (this.preroll.length > 1 && this.prerollSamples - this.preroll[0].length >= max) this.prerollSamples -= this.preroll.shift().length;
    }
  }

  _open() {
    let s = null;
    let live = false;
    s = this.asr.open({
      identity: this.identity,
      onOpen: () => { live = true; this.attempt = 0; },
      onPartial: () => {},
      onFinal: (text) => { live = true; if (!this.closed && text && String(text).trim()) this.onFinal(this.identity, String(text)); },
      onClose: () => {
        if (this.session === s) this.session = null;
        this.audioSec += s?.audioSec ?? 0;
        if (!live && !s._byUs && !this.closed && this.attempt < this.retries) { this.attempt += 1; this.log(`ASR 握手失败,重试 ${this.attempt}`); }
      },
      onError: (e) => this.log(`ASR 出错: ${e?.message ?? e}`),
    });
    this.session = s;
  }

  _armIdle() {
    clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => this._closeSession(), this.idleMs);
    this.idleTimer.unref?.();
  }

  _closeSession() {
    clearTimeout(this.idleTimer);
    const s = this.session;
    this.session = null;
    if (!s) return;
    s._byUs = true;
    Promise.resolve(s.finish?.()).catch(() => {}).finally(() => { try { s.close(); } catch { /* */ } });
  }

  close() {
    this._closeSession();
    this.closed = true;
    this.preroll = [];
    this.prerollSamples = 0;
  }
}
