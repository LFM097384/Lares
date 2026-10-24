// ember-zoom · 侧边栏 WS hub。侧边栏就是「房间」:Ember 的房内消息(state / answer / draft / approvals / released / mem / ended …)
// 只经这里发给本场会议里打开了侧边栏的参会者,永不出门。
//
// 客户端 → hub(JSON,单条 ≤ 16 KB):
//   {t:'zoom_hello', meetingUuid, participantId?, participantUUID?, screenName, role?}   来自侧边栏 zoomSdk.getMeetingUUID() + getUserContext()
//   {t:'zoom_invite'}                    点「邀请炉灵」时先发(记下发起人 = convener 线索),随后侧边栏调 zoomSdk.startRTMS()
//   {t:'zoom_chat_result', draftId, ok}  侧边栏 sendMessageToChat 的结果(只记元数据)
//   其它 {t:'ack'|'ask'|'skill'|'review'|'approve'|'mem_list'|'mem_retract'|'end'}   原样转给 Ember(发送者 = 绑定的 Ember id)
// hub → 客户端:
//   {t:'zoom_welcome', bound, id?, active}   {t:'zoom_session', state:'waiting'|'active'|'ended'}
//   Ember 协议消息原样;port 的 zoom_active / zoom_released_notice / zoom_post_chat / zoom_stop_rtms
//
// 信任边界(README「信任」):身份是侧边栏自报的(getUserContext 没有服务端可验证的签名),hub 只校验 Origin 与会议 UUID。
// 能连上 hub、又知道 meetingUuid 与某人 participantId 的人可以冒充他发 ask / approve。approve 另有 Ed25519 签名,
// 但公钥本身是 ack 时自报的(TOFU,会话内钉住)。加固路线:校验 Zoom Apps 的 x-zoom-app-context 头后签发短期 hub token。
import { WebSocketServer } from './deps.mjs';

export const HUB_PATH = '/hub';
export const MAX_MSG_BYTES = 16 * 1024;
const OPEN = 1;

export class SidebarHub {
  constructor({ log = () => {}, allowOrigins = null, maxMsgBytes = MAX_MSG_BYTES } = {}) {
    this.log = log;
    this.allowOrigins = allowOrigins; // null = 只要求 Origin 与 Host 同源(或无 Origin:非浏览器客户端)
    this.maxMsgBytes = maxMsgBytes;
    this.meetings = new Map(); // meetingUuid → { clients:Set<Client>, port, inviter }
    this.wss = new WebSocketServer({ noServer: true, maxPayload: maxMsgBytes });
    this.wss.on('connection', (ws) => this._onConnection(ws));
  }

  _meeting(uuid) {
    let m = this.meetings.get(uuid);
    if (!m) { m = { clients: new Set(), port: null, inviter: null }; this.meetings.set(uuid, m); }
    return m;
  }

  originOk(req) {
    const origin = req.headers.origin;
    if (!origin) return true;
    if (Array.isArray(this.allowOrigins)) return this.allowOrigins.includes(origin);
    try { return new URL(origin).host === req.headers.host; } catch { return false; }
  }

  /// http server 'upgrade' 处理:路径对、Origin 对才接
  handleUpgrade(req, socket, head) {
    let pathname = '';
    try { pathname = new URL(req.url, 'http://x').pathname; } catch { /* */ }
    if (pathname !== HUB_PATH || !this.originOk(req)) {
      socket.write('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    this.wss.handleUpgrade(req, socket, head, (ws) => this.wss.emit('connection', ws, req));
  }

  _send(c, obj) { try { if (c.ws.readyState === OPEN) c.ws.send(JSON.stringify(obj)); } catch { /* */ } }

  _onConnection(ws) {
    const c = { ws, meetingUuid: null, hello: null, id: null };
    ws.on('message', (data, isBinary) => {
      if (isBinary) return;
      let m;
      try { m = JSON.parse(String(data)); } catch { return; }
      if (!m || typeof m.t !== 'string') return;
      this._onClientMessage(c, m);
    });
    ws.on('close', () => {
      if (!c.meetingUuid) return;
      const mt = this.meetings.get(c.meetingUuid);
      mt?.clients.delete(c);
      if (mt && !mt.clients.size && !mt.port) this.meetings.delete(c.meetingUuid);
    });
    ws.on('error', () => {});
  }

  _onClientMessage(c, m) {
    if (m.t === 'zoom_hello') {
      if (c.meetingUuid) return this._send(c, { t: 'error', op: 'zoom_hello', code: 'already_hello' });
      const meetingUuid = String(m.meetingUuid ?? '').slice(0, 200);
      if (!meetingUuid) return this._send(c, { t: 'error', op: 'zoom_hello', code: 'bad_request' });
      c.meetingUuid = meetingUuid;
      c.hello = {
        participantId: m.participantId != null ? String(m.participantId).slice(0, 100) : null,
        participantUUID: m.participantUUID != null ? String(m.participantUUID).slice(0, 200) : null,
        screenName: String(m.screenName ?? '').slice(0, 200),
        role: String(m.role ?? '').slice(0, 40),
      };
      const mt = this._meeting(meetingUuid);
      mt.clients.add(c);
      if (mt.port) this._bind(mt, c);
      this._send(c, { t: 'zoom_welcome', bound: Boolean(c.id), ...(c.id ? { id: c.id } : {}), active: Boolean(mt.port) });
      if (!mt.port) this._send(c, { t: 'zoom_session', state: 'waiting' });
      return undefined;
    }
    if (!c.meetingUuid) return this._send(c, { t: 'error', op: m.t, code: 'no_hello' });
    const mt = this.meetings.get(c.meetingUuid);
    if (m.t === 'zoom_invite') { if (mt) mt.inviter = { ...c.hello }; return undefined; }
    if (m.t === 'zoom_chat_result') { this.log(`chat post ${m.ok ? 'ok' : 'failed'} (draft ${String(m.draftId).slice(0, 40)})`); return undefined; }
    if (m.t.startsWith('zoom_')) return this._send(c, { t: 'error', op: m.t, code: 'unknown_op' });
    if (!mt?.port) return this._send(c, { t: 'error', op: m.t, code: 'no_session' });
    if (!c.id) this._bind(mt, c);
    if (!c.id) return this._send(c, { t: 'error', op: m.t, code: 'unbound' });
    mt.port._fromSidebar(c.id, m);
    return undefined;
  }

  _bind(mt, c) {
    const id = mt.port._bindSidebar(c.hello);
    if (!id) return;
    c.id = id;
    this._send(c, { t: 'zoom_welcome', bound: true, id, active: true });
  }

  // ── port 面 ──
  /// 会话开始:port 接管该会议;等着的侧边栏立即绑定
  attachPort(meetingUuid, port) {
    const mt = this._meeting(meetingUuid);
    if (mt.port && mt.port !== port) throw new Error('hub: meeting already has an active session');
    mt.port = port;
    for (const c of mt.clients) if (!c.id) this._bind(mt, c);
  }
  detachPort(meetingUuid, port) {
    const mt = this.meetings.get(meetingUuid);
    if (!mt || mt.port !== port) return;
    mt.port = null;
    mt.inviter = null;
    for (const c of mt.clients) { c.id = null; this._send(c, { t: 'zoom_session', state: 'ended' }); }
    if (!mt.clients.size) this.meetings.delete(meetingUuid);
  }
  inviterOf(meetingUuid) { return this.meetings.get(meetingUuid)?.inviter ?? null; }

  /// toId 为 null → 该会议全部已绑定侧边栏;否则只发给绑定到 toId 的侧边栏(同一人可能开了多个)
  sendTo(meetingUuid, obj, toId = null, { unbound = false } = {}) {
    const mt = this.meetings.get(meetingUuid);
    if (!mt) return 0;
    let n = 0;
    for (const c of mt.clients) {
      if (toId ? c.id !== toId : !(c.id || unbound)) continue;
      this._send(c, obj);
      n += 1;
    }
    return n;
  }
  boundIds(meetingUuid) { return [...new Set([...(this.meetings.get(meetingUuid)?.clients ?? [])].map((c) => c.id).filter(Boolean))]; }

  close() {
    for (const c of this.wss.clients) { try { c.terminate(); } catch { /* */ } }
    this.wss.close();
    this.meetings.clear();
  }
}
