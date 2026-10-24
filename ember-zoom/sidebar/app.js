// 炉灵 · Zoom App 侧边栏(vanilla JS,无构建)。侧边栏就是「房间」:炉灵的房内消息只出现在这里。
// 身份:zoomSdk.getMeetingUUID() + getUserContext() 自报给 hub(信任边界见 ember-zoom/README.md「信任」)。
// 签名:每个参会者的 Ed25519 私钥在本侧边栏内生成(WebCrypto,不可导出),只在本页内存里,关掉即忘。
// 开发模式(不在 Zoom 客户端里):?dev=1&meeting=<uuid>&pid=<participantId>&name=<显示名>
'use strict';
(() => {
  const $ = (id) => document.getElementById(id);
  const el = (tag, props = {}, ...kids) => { const e = document.createElement(tag); Object.assign(e, props); for (const k of kids) e.append(k); return e; };
  const params = new URLSearchParams(location.search);
  const S = { ws: null, me: null, myId: null, state: null, drafts: new Map(), key: null, pubB64: null, acked: false, inZoom: false, retry: 0, hello: null, chatOk: false };

  const setStatus = (text, on = false) => { $('status').textContent = text; $('status').classList.toggle('on', on); };
  const show = (id, yes) => { $(id).hidden = !yes; };

  // ── 规范 JSON(与 ember/core/crypto.mjs 的 canonicalJSON 一致:键排序、无空白)──
  const canon = (v) => {
    if (v === null || typeof v !== 'object') return JSON.stringify(v);
    if (Array.isArray(v)) return `[${v.map(canon).join(',')}]`;
    return `{${Object.keys(v).filter((k) => v[k] !== undefined).sort().map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(',')}}`;
  };
  const b64 = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf)));
  const nonce = () => b64(crypto.getRandomValues(new Uint8Array(16)).buffer).replace(/=+$/, '');

  async function ensureKey() {
    if (S.key) return;
    const kp = await crypto.subtle.generateKey({ name: 'Ed25519' }, false, ['sign', 'verify']);
    S.key = kp.privateKey;
    S.pubB64 = b64(await crypto.subtle.exportKey('raw', kp.publicKey));
  }
  async function sign(message) { return b64(await crypto.subtle.sign({ name: 'Ed25519' }, S.key, new TextEncoder().encode(message))); }

  // ── Zoom SDK ──
  async function zoomContext() {
    if (window.zoomSdk && !params.has('dev')) {
      try {
        const cfg = await zoomSdk.config({ capabilities: ['getMeetingUUID', 'getUserContext', 'startRTMS', 'stopRTMS', 'getRTMSStatus', 'onRTMSStatusChange', 'sendMessageToChat'] });
        S.inZoom = true;
        S.chatOk = !(cfg?.unsupportedApis ?? []).includes('sendMessageToChat');
        const { meetingUUID } = await zoomSdk.getMeetingUUID();
        const u = await zoomSdk.getUserContext();
        try { zoomSdk.onRTMSStatusChange?.((e) => { $('foot').textContent = `RTMS: ${e?.status ?? JSON.stringify(e)}`; }); } catch { /* */ }
        return { meetingUuid: meetingUUID, participantId: u.participantId ?? null, participantUUID: u.participantUUID ?? null, screenName: u.screenName ?? '', role: u.role ?? '' };
      } catch (e) {
        setStatus('不在 Zoom 会议中');
        $('foot').textContent = `Zoom SDK 不可用：${e?.message ?? e}`;
      }
    }
    if (params.get('dev') === '1' && params.get('meeting')) {
      return { meetingUuid: params.get('meeting'), participantId: params.get('pid'), participantUUID: params.get('puuid') || params.get('pid'), screenName: params.get('name') || '', role: params.get('role') || '' };
    }
    return null;
  }

  // ── hub ──
  function send(obj) { if (S.ws?.readyState === 1) S.ws.send(JSON.stringify(obj)); }
  function connect() {
    const ws = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/hub`);
    S.ws = ws;
    ws.onopen = () => { S.retry = 0; send({ t: 'zoom_hello', ...S.hello }); };
    ws.onmessage = (e) => { let m; try { m = JSON.parse(e.data); } catch { return; } onMsg(m); };
    ws.onclose = () => {
      setStatus('已断开，重连中…');
      S.myId = null; S.acked = false;
      const d = Math.min(30000, 1000 * 2 ** S.retry++);
      setTimeout(connect, d);
    };
  }

  function onMsg(m) {
    switch (m.t) {
      case 'zoom_welcome':
        if (m.bound) { S.myId = m.id; setStatus('炉灵在场', true); }
        else setStatus(m.active ? '炉灵在场（未绑定）' : '炉灵未在场');
        render();
        break;
      case 'zoom_session':
        if (m.state === 'waiting') setStatus('炉灵未在场');
        if (m.state === 'ended') { setStatus('炉灵已离开'); S.myId = null; S.acked = false; S.state = null; S.drafts.clear(); render(); }
        break;
      case 'zoom_active': setStatus(m.on ? '炉灵在场' : '炉灵已离开', m.on); break;
      case 'zoom_stop_rtms': if (S.inZoom) zoomSdk.stopRTMS?.().catch(() => {}); break;
      case 'zoom_post_chat': postChat(m); break;
      case 'zoom_released_notice': break;
      case 'state': S.state = m; S.acked = Boolean(m.members?.find((x) => x.id === S.myId)?.acked); render(); break;
      case 'answer': addAnswer(m.q, m.a); break;
      case 'draft': S.drafts.set(m.draft.draftId, { draft: m.draft, count: 0, k: m.draft.k, mine: false }); renderDrafts(); break;
      case 'approvals': { const d = S.drafts.get(m.draftId); if (d) { d.count = m.count; d.k = m.k; if (m.count === 0) d.mine = false; renderDrafts(); } break; }
      case 'released': { S.drafts.delete(m.draftId); renderDrafts(); addReleased(m.text); break; }
      case 'mem': renderMem(m.items); break;
      case 'mem_retracted': send({ t: 'mem_list' }); break;
      case 'ended': setStatus('已散会'); S.state = null; S.drafts.clear(); render(); break;
      case 'error': $('foot').textContent = `错误：${m.op} · ${m.code}`; break;
      default: break;
    }
  }

  // ── 渲染(一律 textContent,不拼 HTML)──
  function render() {
    const st = S.state;
    const live = Boolean(st?.active && S.myId);
    show('session', live); show('ask', live && S.acked); show('drafts', live && S.acked && S.drafts.size > 0);
    show('memory', live && S.acked); show('end', live && S.acked && st.convenerId === S.myId);
    if (!st) return;
    $('kinfo').textContent = `放行门槛 k = ${st.k}`;
    const ul = $('members'); ul.replaceChildren();
    for (const p of st.members ?? []) ul.append(el('li', { className: p.acked ? 'acked' : '', textContent: p.id === S.myId ? `${p.name || '我'}（我）` : (p.name || '参会者') }));
    $('btn-ack').disabled = S.acked;
    $('ackinfo').textContent = S.acked ? '已同意：炉灵会处理你的发言' : '未同意：炉灵会丢弃你的发言';
  }
  function addAnswer(q, a) {
    $('answers').prepend(el('li', {}, el('div', { className: 'q', textContent: `问：${q}` }), el('div', { textContent: a })));
  }
  function addReleased(text) {
    show('released', true);
    $('released-list').prepend(el('pre', { textContent: text }));
  }
  function renderDrafts() {
    const box = $('draft-list'); box.replaceChildren();
    for (const d of S.drafts.values()) {
      const wrap = el('div', { className: 'draft' });
      wrap.append(el('div', { className: 'muted', textContent: `${d.draft.notice} · 签名 ${d.count}/${d.k}` }));
      for (const it of d.draft.items) {
        const row = el('div', { className: `item${it.roleRisk ? ' risk' : ''}` });
        row.append(el('span', { textContent: `【${it.topic}】${it.text}` }));
        if (it.roleRisk) row.append(el('span', { className: 'tag', textContent: '可能认出是谁 · 不处理则不出门' }));
        for (const [action, label] of [['keep', '保留'], ['generalise', '泛化'], ['cut', '删去']]) {
          if (action === 'keep' && !it.roleRisk) continue;
          row.append(el('button', { className: 'ghost', textContent: label, onclick: () => send({ t: 'review', draftId: d.draft.draftId, itemId: it.id, action }) }));
        }
        wrap.append(row);
      }
      const approve = el('button', { textContent: d.mine ? '已签名' : '我签名同意放行', disabled: d.mine });
      approve.onclick = async () => {
        await ensureKey();
        const n = nonce();
        const sig = await sign(canon({ sid: S.state.sid, draftId: d.draft.draftId, draftHash: d.draft.draftHash, nonce: n }));
        d.mine = true; renderDrafts();
        send({ t: 'approve', draftId: d.draft.draftId, draftHash: d.draft.draftHash, nonce: n, sig });
      };
      wrap.append(el('div', { className: 'row' }, approve));
      box.append(wrap);
    }
    show('drafts', S.drafts.size > 0 && S.acked);
  }
  function renderMem(items) {
    const ul = $('mem-list'); ul.replaceChildren();
    if (!items.length) ul.append(el('li', { className: 'muted', textContent: '（空）' }));
    for (const it of items) {
      ul.append(el('li', {}, el('span', { textContent: it.text }), el('button', { className: 'ghost', textContent: '撤回', onclick: () => send({ t: 'mem_retract', itemId: it.id }) })));
    }
  }
  async function postChat(m) {
    // 唯一会去会议聊天的内容:k 人签名放行的纪要(服务器只在 EMBER_ZOOM_POST_CHAT=1 时发来)
    let ok = false;
    if (S.inZoom && S.chatOk && zoomSdk.sendMessageToChat) {
      try { await zoomSdk.sendMessageToChat({ message: String(m.text).slice(0, 4000) }); ok = true; } catch { ok = false; }
    }
    send({ t: 'zoom_chat_result', draftId: m.draftId, ok });
  }

  // ── 按钮 ──
  $('btn-invite').onclick = async () => {
    send({ t: 'zoom_invite' });
    if (!S.inZoom) { $('foot').textContent = '开发模式：请用模拟器发 rtms_started'; return; }
    try { await zoomSdk.startRTMS(); setStatus('已请求，等待主持人允许…'); } catch (e) { $('foot').textContent = `startRTMS 失败：${e?.message ?? e}`; }
  };
  $('btn-leave').onclick = async () => {
    if (S.inZoom) { try { await zoomSdk.stopRTMS(); } catch (e) { $('foot').textContent = `stopRTMS 失败：${e?.message ?? e}`; } }
  };
  $('btn-ack').onclick = async () => {
    try { await ensureKey(); } catch (e) { $('foot').textContent = `本客户端不支持 Ed25519 签名：${e?.message ?? e}`; return; }
    send({ t: 'ack', pubKey: S.pubB64 });
  };
  $('ask-form').onsubmit = (e) => { e.preventDefault(); const q = $('q').value.trim(); if (!q) return; send({ t: 'ask', q }); $('q').value = ''; };
  $('btn-minutes').onclick = () => send({ t: 'skill', name: 'minutes', args: {} });
  $('btn-mem').onclick = () => send({ t: 'mem_list' });
  $('btn-end').onclick = () => { if (confirm('散会后炉灵清空本场一切原话与草稿，确定？')) send({ t: 'end' }); };

  (async () => {
    S.hello = await zoomContext();
    if (!S.hello) { setStatus('请在 Zoom 会议里打开'); return; }
    connect();
  })();
})();
