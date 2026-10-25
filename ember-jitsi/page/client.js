// ember-jitsi · 浏览器内的 Jitsi 参与者(无头 Chromium 里跑;炉灵 bot 与 e2e 的模拟真人共用)。
// 页面由 bridge 以 page.route 挂在 Jitsi 服务器同源路径下,先加载该服务器的 /config.js 与 /libs/lib-jitsi-meet.min.js。
// 与 Node 的接口:
//   Node → 页面:window.ember.{start(opts), sendPublic(text), sendPrivate(id, text), addMic(), leave()}
//   页面 → Node:window.emberEvent(obj)  — 只有元数据与聊天(聊天就是房间通道)
//               window.emberAudio(id, b64)  — 某远端 endpoint 的 16 kHz 单声道 Int16 PCM(100 ms 一帧)
// 本页不打印任何聊天或语音内容到 console。
/* global JitsiMeetJS, config */
(() => {
  // 诊断:记下页面里的 RTCPeerConnection(只用于 getStats)
  window.__pcs = [];
  const RPC = window.RTCPeerConnection;
  if (RPC) window.RTCPeerConnection = function (...a) { const pc = new RPC(...a); window.__pcs.push(pc); return pc; };
  if (RPC) window.RTCPeerConnection.prototype = RPC.prototype;
  const E = (o) => { try { window.emberEvent(o); } catch { /* */ } };
  const st = { conn: null, conf: null, tracks: new Map(), ctx: null, workletReady: null, myId: null, left: false, opts: {} };

  const WORKLET = `
class EmberTap extends AudioWorkletProcessor {
  constructor() { super(); this.buf = new Int16Array(1600); this.n = 0; }
  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (ch) for (let i = 0; i < ch.length; i++) {
      const v = Math.max(-1, Math.min(1, ch[i]));
      this.buf[this.n++] = v < 0 ? v * 0x8000 : v * 0x7fff;
      if (this.n === this.buf.length) { this.port.postMessage(this.buf.slice(0)); this.n = 0; }
    }
    return true;
  }
}
registerProcessor('ember-tap', EmberTap);`;

  function b64(i16) {
    const u8 = new Uint8Array(i16.buffer, i16.byteOffset, i16.byteLength);
    let s = '';
    for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
    return btoa(s);
  }

  async function audioCtx() {
    if (!st.ctx) {
      st.ctx = new AudioContext({ sampleRate: 16000 });
      const url = URL.createObjectURL(new Blob([WORKLET], { type: 'application/javascript' }));
      st.workletReady = st.ctx.audioWorklet.addModule(url);
    }
    await st.workletReady;
    if (st.ctx.state !== 'running') { try { await st.ctx.resume(); } catch { /* */ } }
    return st.ctx;
  }

  async function tapTrack(track) {
    const id = track.getParticipantId();
    const key = track.getTrackId?.() ?? `${id}:${Math.random()}`;
    if (st.tracks.has(key)) return;
    const ms = new MediaStream([track.getTrack()]);
    // Chromium:远端 WebRTC 流不挂到媒体元素上时 WebAudio 收不到数据,挂一个静音 <audio>
    const el = document.createElement('audio');
    el.muted = true; el.autoplay = true; el.srcObject = ms;
    document.body.appendChild(el);
    try { await el.play(); } catch { /* */ }
    const ctx = await audioCtx();
    const src = ctx.createMediaStreamSource(ms);
    const node = new AudioWorkletNode(ctx, 'ember-tap');
    node.port.onmessage = (e) => { if (!st.left) { try { window.emberAudio(id, b64(e.data)); } catch { /* */ } } };
    src.connect(node);
    const sink = ctx.createGain(); sink.gain.value = 0; node.connect(sink); sink.connect(ctx.destination);
    st.tracks.set(key, { id, el, src, node });
    E({ ev: 'track', id });
  }
  function untapTrack(track) {
    const key = track.getTrackId?.();
    const t = st.tracks.get(key);
    if (!t) return;
    try { t.src.disconnect(); t.node.disconnect(); t.el.srcObject = null; t.el.remove(); } catch { /* */ }
    st.tracks.delete(key);
  }

  function start(opts) {
    st.opts = opts;
    const JM = JitsiMeetJS;
    JM.init({ disableAudioLevels: true });
    JM.setLogLevel(window.__EMBER_DEBUG ? JM.logLevels.DEBUG : JM.logLevels.ERROR);
    const room = String(opts.room).toLowerCase();
    let serviceUrl = config.websocket || config.bosh;
    serviceUrl += (serviceUrl.includes('?') ? '&' : '?') + `room=${encodeURIComponent(room)}`;
    const conn = new JM.JitsiConnection(null, null, { hosts: config.hosts, serviceUrl, websocketKeepAliveUrl: config.websocketKeepAliveUrl });
    st.conn = conn;
    const CE = JM.events.connection;
    const C = JM.events.conference;
    return new Promise((resolve, reject) => {
      const to = setTimeout(() => reject(new Error('join_timeout')), opts.timeoutMs || 30000);
      conn.addEventListener(CE.CONNECTION_FAILED, (e) => { clearTimeout(to); E({ ev: 'disconnected', reason: `connection_failed:${e}` }); reject(new Error(`connection_failed:${e}`)); });
      conn.addEventListener(CE.CONNECTION_DISCONNECTED, () => { if (!st.left) E({ ev: 'disconnected', reason: 'connection_disconnected' }); });
      conn.addEventListener(CE.CONNECTION_ESTABLISHED, () => {
        const conf = conn.initJitsiConference(room, { p2p: { enabled: false }, ...(config.e2eping ? {} : {}) });
        st.conf = conf;
        conf.setDisplayName(opts.name);
        conf.on(C.CONFERENCE_JOINED, () => {
          clearTimeout(to);
          st.myId = conf.myUserId();
          for (const p of conf.getParticipants()) E({ ev: 'participant', id: p.getId(), name: p.getDisplayName() || '', hidden: Boolean(p.isHidden?.()) });
          E({ ev: 'joined', id: st.myId });
          resolve(st.myId);
        });
        conf.on(C.CONFERENCE_FAILED, (e) => { clearTimeout(to); E({ ev: 'disconnected', reason: `conference_failed:${e}` }); reject(new Error(`conference_failed:${e}`)); });
        conf.on(C.KICKED, () => E({ ev: 'disconnected', reason: 'kicked' }));
        conf.on(C.USER_JOINED, (id, user) => E({ ev: 'participant', id, name: user.getDisplayName() || '', hidden: Boolean(user.isHidden?.()) }));
        conf.on(C.USER_LEFT, (id) => E({ ev: 'left', id }));
        conf.on(C.DISPLAY_NAME_CHANGED, (id, name) => E({ ev: 'name', id, name: name || '' }));
        conf.on(C.MESSAGE_RECEIVED, (id, text) => { if (id && id !== st.myId) E({ ev: 'chat', id, text: String(text ?? ''), private: false }); });
        conf.on(C.PRIVATE_MESSAGE_RECEIVED, (id, text) => { if (id && id !== st.myId) E({ ev: 'chat', id, text: String(text ?? ''), private: true }); });
        if (opts.tapAudio) {
          conf.on(C.TRACK_ADDED, (track) => { if (!track.isLocal() && track.getType() === 'audio') void tapTrack(track).catch((e) => E({ ev: 'warn', where: 'tap', message: String(e?.message ?? e) })); });
          conf.on(C.TRACK_REMOVED, (track) => { if (!track.isLocal()) untapTrack(track); });
        }
        conf.join();
      });
      conn.connect();
    });
  }

  async function addMic() {
    const [t] = await JitsiMeetJS.createLocalTracks({ devices: ['audio'] });
    await st.conf.addTrack(t);
    st.mic = t;
    return true;
  }

  async function leave() {
    if (st.left) return;
    st.left = true;
    try { await st.conf?.leave(); } catch { /* */ }
    try { st.conn?.disconnect(); } catch { /* */ }
    try { await st.ctx?.close(); } catch { /* */ }
  }

  window.ember = {
    start,
    addMic,
    leave,
    myId: () => st.myId,
    sendPublic: (text) => { st.conf.sendTextMessage(String(text)); return true; },
    sendPrivate: (id, text) => { st.conf.sendPrivateTextMessage(String(id), String(text)); return true; },
    participants: () => (st.conf ? st.conf.getParticipants().map((p) => ({ id: p.getId(), name: p.getDisplayName() || '' })) : []),
  };
  E({ ev: 'page_ready' });
})();
