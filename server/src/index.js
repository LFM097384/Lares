// Lares 一键进圈 — presence 信令服务
// 职责:维护「谁在哪个圈子房间」「轻状态」实时广播,并为进房成员签发 LiveKit token。
// MVP:内存态,单进程。后续按设计.md §4.2 演进为 Redis Pub/Sub 集群。

import http from 'node:http';
import { mkdir, readdir, readFile, writeFile, unlink } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import { AccessToken } from 'livekit-server-sdk';

const PORT = Number(process.env.LARES_PORT ?? 8787);
const LIVEKIT_URL = process.env.LIVEKIT_URL ?? '';
const LIVEKIT_API_KEY = process.env.LIVEKIT_API_KEY ?? '';
const LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET ?? '';
const RTC_CONFIGURED = Boolean(LIVEKIT_URL && LIVEKIT_API_KEY && LIVEKIT_API_SECRET);

// ── 房间状态 ──────────────────────────────────────────────────────────────
// circleId -> Map<userId, Member>
// Member = { userId, name, status, devices: Map<deviceId, ws> }
const circles = new Map();

// ── 敲门模式(设计.md §3.3):圈子可设「需轻量提示允许」──
// circleId -> { knockRequired: boolean },磁盘持久化
const DATA_DIR = process.env.LARES_DATA_DIR
  ?? path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'data');
const SETTINGS_FILE = path.join(DATA_DIR, 'circle_settings.json');
let circleSettings = {};

// circleId -> Map<userId, {ws, session}>:等待应门的敲门者
const pendingKnocks = new Map();

async function loadSettings() {
  try {
    circleSettings = JSON.parse(await readFile(SETTINGS_FILE, 'utf8'));
  } catch { /* 首次运行 */ }
}

function saveSettings() {
  mkdir(DATA_DIR, { recursive: true })
    .then(() => writeFile(SETTINGS_FILE, JSON.stringify(circleSettings)))
    .catch((e) => console.error('[settings] 保存失败:', e));
}

const VALID_STATUS = new Set(['free', 'busy', 'ears', 'away']);

function getCircle(circleId) {
  if (!circles.has(circleId)) circles.set(circleId, new Map());
  return circles.get(circleId);
}

function memberSnapshot(member) {
  return {
    userId: member.userId,
    name: member.name,
    status: member.status,
    deviceCount: member.devices.size,
    // 位置共享:有则带上(后进房的人也能看到)
    ...(member.loc ? { loc: member.loc } : {}),
  };
}

function roomSnapshot(circleId) {
  const members = [...getCircle(circleId).values()].map(memberSnapshot);
  return { t: 'room', circleId, members };
}

function broadcast(circleId, msg, exceptWs = null) {
  const data = JSON.stringify(msg);
  for (const member of getCircle(circleId).values()) {
    for (const ws of member.devices.values()) {
      if (ws !== exceptWs && ws.readyState === ws.OPEN) ws.send(data);
    }
  }
}

// ── 大厅 presence 摘要(未进房也要能看到「X 人在」,设计.md §3.2-1)──
const lobby = new Set(); // 所有已 hello 的连接

function circleSummaryMsg(circleId) {
  const members = [...(circles.get(circleId)?.values() ?? [])];
  return {
    t: 'circle_summary',
    circleId,
    count: members.length,
    names: members.map((m) => m.name),
    knockRequired: circleSettings[circleId]?.knockRequired === true,
  };
}

function broadcastLobbySummary(circleId) {
  const data = JSON.stringify(circleSummaryMsg(circleId));
  for (const ws of lobby) {
    if (ws.readyState === ws.OPEN) ws.send(data);
  }
}

async function mintLiveKitToken(circleId, userId, name) {
  const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
    identity: userId,
    name,
    // token 短寿命,进房即签,降低泄露面
    ttl: '2h',
  });
  at.addGrant({ roomJoin: true, room: circleId, canPublish: true, canSubscribe: true });
  return at.toJwt();
}

// ── 连接会话 ──────────────────────────────────────────────────────────────
function handleConnection(ws) {
  // 每条连接绑定 (userId, deviceId);一个用户可多端在线
  const session = { userId: null, deviceId: null, circleId: null };

  ws.on('message', async (raw) => {
    // 消息体上限 64KB(防内存 DoS;正常协议消息 << 1KB)
    if (raw.length > 64 * 1024) return send(ws, { t: 'error', message: 'too_large' });
    let msg;
    try { msg = JSON.parse(raw); } catch { return send(ws, { t: 'error', message: 'bad_json' }); }

    switch (msg.t) {
      case 'hello': {
        if (typeof msg.userId !== 'string' || !msg.userId) return send(ws, { t: 'error', message: 'userId_required' });
        session.userId = msg.userId;
        session.deviceId = typeof msg.deviceId === 'string' && msg.deviceId ? msg.deviceId : crypto.randomUUID();
        session.name = typeof msg.name === 'string' && msg.name ? msg.name.slice(0, 24) : '圈友';
        session.platform = typeof msg.platform === 'string' ? msg.platform : 'unknown';
        send(ws, { t: 'welcome', userId: session.userId, deviceId: session.deviceId, rtcConfigured: RTC_CONFIGURED });
        // 加入大厅并立即下发所有非空圈子的在线摘要
        lobby.add(ws);
        for (const [circleId] of circles) send(ws, circleSummaryMsg(circleId));
        break;
      }

      case 'join': {
        if (!session.userId) return send(ws, { t: 'error', message: 'say_hello_first' });
        const circleId = typeof msg.circleId === 'string' && msg.circleId ? msg.circleId : 'home';
        // 敲门模式:圈内有人时需里面的人放行;空房直接进(没人可问)
        if (circleSettings[circleId]?.knockRequired && getCircle(circleId).size > 0) {
          if (!pendingKnocks.has(circleId)) pendingKnocks.set(circleId, new Map());
          pendingKnocks.get(circleId).set(session.userId, { ws, session });
          send(ws, { t: 'knock_waiting', circleId });
          broadcast(circleId, { t: 'knock', circleId, userId: session.userId, name: session.name });
          break;
        }
        await joinCircle(ws, session, circleId);
        break;
      }

      case 'knock_allow': {
        // 授权检查:只有圈内成员才能放行(否则敲门形同虚设)
        const circleId = typeof msg.circleId === 'string' ? msg.circleId : '';
        const approver = circleId ? getCircle(circleId).get(session.userId) : null;
        if (!approver || !approver.devices.has(session.deviceId)) return;
        const pending = pendingKnocks.get(circleId);
        const target = pending?.get(msg.userId);
        if (!target) return;
        pending.delete(msg.userId);
        await joinCircle(target.ws, target.session, circleId);
        break;
      }

      case 'kick': {
        // 踢人:圈内成员可把目标用户请出房间(非封禁,可再进)
        const circleId = typeof msg.circleId === 'string' ? msg.circleId : '';
        const targetId = typeof msg.userId === 'string' ? msg.userId : '';
        const circle = circleId ? getCircle(circleId) : null;
        const actor = circle?.get(session.userId);
        // 授权:发起者必须是圈内成员;不能踢自己
        if (!actor || !actor.devices.has(session.deviceId) || !targetId || targetId === session.userId) return;
        const target = circle.get(targetId);
        if (!target) return;
        // 先通知目标端,再移出房间
        for (const tws of target.devices.values()) {
          send(tws, { t: 'kicked', circleId, by: actor.name });
        }
        circle.delete(targetId);
        broadcast(circleId, { t: 'member_left', circleId, userId: targetId });
        if (circle.size === 0) circles.delete(circleId);
        broadcastLobbySummary(circleId);
        break;
      }

      case 'loc': {
        // 位置共享(Snapchat 式):仅转发给同房成员,不落盘
        if (!session.circleId || !session.userId) return;
        const member = getCircle(session.circleId).get(session.userId);
        if (!member) return;
        const lat = Number(msg.lat), lng = Number(msg.lng);
        if (!Number.isFinite(lat) || !Number.isFinite(lng)) return;
        member.loc = { lat, lng, ts: Date.now() };
        broadcast(session.circleId, {
          t: 'member_loc',
          circleId: session.circleId,
          userId: session.userId,
          name: member.name,
          lat,
          lng,
          ts: member.loc.ts,
        });
        break;
      }

      case 'loc_off': {
        // 关闭共享:广播清除自己的位置
        if (!session.circleId || !session.userId) return;
        const member = getCircle(session.circleId).get(session.userId);
        if (member) delete member.loc;
        broadcast(session.circleId, { t: 'member_loc_off', circleId: session.circleId, userId: session.userId });
        break;
      }

      case 'knock_mode_set': {
        if (typeof msg.circleId !== 'string' || typeof msg.enabled !== 'boolean') return;
        // 授权:圈内成员可改;空圈任何人可预设(创建者场景)
        const circle = getCircle(msg.circleId);
        if (circle.size > 0) {
          const setter = circle.get(session.userId);
          if (!setter || !setter.devices.has(session.deviceId)) return;
        }
        circleSettings[msg.circleId] = { knockRequired: msg.enabled };
        saveSettings();
        broadcastLobbySummary(msg.circleId);
        break;
      }

      case 'leave': {
        leaveCircle(ws, session);
        break;
      }

      case 'token_prefetch': {
        // 预热(P0):App 启动即备好 RTC token,进房时信令与媒体连接并行
        if (!session.userId || !RTC_CONFIGURED) return;
        const circleId = typeof msg.circleId === 'string' && msg.circleId ? msg.circleId : 'home';
        try {
          const token = await mintLiveKitToken(circleId, session.userId, session.name);
          send(ws, { t: 'token', circleId, url: LIVEKIT_URL, token, prefetch: true });
        } catch (err) {
          console.error('[token] prefetch failed:', err);
        }
        break;
      }

      case 'profile': {
        // 改名:更新会话与房间成员记录,广播给同房成员与大厅
        if (typeof msg.name !== 'string' || !msg.name.trim()) return;
        const name = msg.name.trim().slice(0, 24);
        session.name = name;
        if (session.circleId && session.userId) {
          const member = getCircle(session.circleId).get(session.userId);
          if (member) {
            member.name = name;
            broadcast(session.circleId, { t: 'member_updated', circleId: session.circleId, member: memberSnapshot(member) });
            broadcastLobbySummary(session.circleId);
          }
        }
        break;
      }

      case 'status': {
        if (!session.circleId || !session.userId) return;
        const status = VALID_STATUS.has(msg.status) ? msg.status : 'free';
        const member = getCircle(session.circleId).get(session.userId);
        if (!member) return;
        member.status = status;
        broadcast(session.circleId, { t: 'member_status', circleId: session.circleId, userId: session.userId, status });
        break;
      }

      case 'ping': {
        send(ws, { t: 'pong', now: Date.now() });
        break;
      }
    }
  });

  ws.on('close', () => {
    lobby.delete(ws);
    leaveCircle(ws, session);
    // 清理未应门的敲门请求
    for (const pending of pendingKnocks.values()) pending.delete(session.userId);
  });
  ws.on('error', () => { lobby.delete(ws); leaveCircle(ws, session); });
}

/// 执行进房(直接进 / 敲门放行后):换圈、登记成员、发房间快照与 RTC token
async function joinCircle(ws, session, circleId) {
  // 先退出旧圈子(MVP:同时只在一个圈子的房间里)
  if (session.circleId) leaveCircle(ws, session);
  session.circleId = circleId;
  const circle = getCircle(circleId);
  const existing = circle.get(session.userId);
  if (existing) {
    existing.devices.set(session.deviceId, ws);
    existing.name = session.name;
    send(ws, roomSnapshot(circleId));
  } else {
    const member = { userId: session.userId, name: session.name, status: 'free', devices: new Map([[session.deviceId, ws]]) };
    circle.set(session.userId, member);
    broadcast(circleId, { t: 'member_joined', circleId, member: memberSnapshot(member) }, ws);
    send(ws, roomSnapshot(circleId));
    broadcastLobbySummary(circleId);
  }
  // 签发 RTC token
  if (RTC_CONFIGURED) {
    try {
      const token = await mintLiveKitToken(circleId, session.userId, session.name);
      send(ws, { t: 'token', circleId, url: LIVEKIT_URL, token });
    } catch (err) {
      send(ws, { t: 'error', message: 'token_failed' });
      console.error('[token] mint failed:', err);
    }
  } else {
    send(ws, { t: 'error', message: 'rtc_not_configured' });
  }
}

function leaveCircle(ws, session) {
  if (!session.circleId || !session.userId) return;
  const circle = getCircle(session.circleId);
  const member = circle.get(session.userId);
  if (member) {
    member.devices.delete(session.deviceId);
    // 同一用户所有端都离开才算「出房」
    if (member.devices.size === 0) {
      circle.delete(session.userId);
      broadcast(session.circleId, { t: 'member_left', circleId: session.circleId, userId: session.userId });
      if (circle.size === 0) circles.delete(session.circleId);
      broadcastLobbySummary(session.circleId);
    }
  }
  session.circleId = null;
}

function send(ws, msg) {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
}

// ── 语音便签(设计.md §2.2:圈子里没人时,留一条 15s 语音)──
// MVP:磁盘 JSON 存储(audio 为 base64),听过即删。后续演进:对象存储 + 转码队列。
const NOTES_DIR = path.join(DATA_DIR, 'notes');
const NOTE_MAX_SECONDS = 15;
const NOTE_MAX_BYTES = 2 * 1024 * 1024; // base64 后上限

async function noteDir(circleId) {
  const dir = path.join(NOTES_DIR, encodeURIComponent(circleId));
  await mkdir(dir, { recursive: true });
  return dir;
}

async function listNotes(circleId) {
  try {
    const dir = await noteDir(circleId);
    const files = await readdir(dir);
    const notes = [];
    for (const f of files.filter((f) => f.endsWith('.json'))) {
      try {
        notes.push(JSON.parse(await readFile(path.join(dir, f), 'utf8')));
      } catch { /* 跳过坏文件 */ }
    }
    return notes.sort((a, b) => a.createdAt - b.createdAt);
  } catch {
    return [];
  }
}

async function saveNote(circleId, note) {
  const dir = await noteDir(circleId);
  await writeFile(path.join(dir, `${note.id}.json`), JSON.stringify(note));
}

async function deleteNote(circleId, id) {
  try {
    await unlink(path.join(NOTES_DIR, encodeURIComponent(circleId), `${id}.json`));
  } catch { /* 已不存在 */ }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > NOTE_MAX_BYTES * 2) req.destroy();
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

// ── HTTP + WS 服务 ────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const json = (code, obj) => {
    res.writeHead(code, {
      'content-type': 'application/json',
      'access-control-allow-origin': '*',
      'access-control-allow-methods': 'GET,POST,DELETE,OPTIONS',
      'access-control-allow-headers': 'content-type',
    });
    res.end(JSON.stringify(obj));
  };
  if (req.method === 'OPTIONS') return json(204, {});

  if (url.pathname === '/health') {
    const summary = {};
    for (const [circleId, members] of circles) summary[circleId] = members.size;
    return json(200, { ok: true, rtcConfigured: RTC_CONFIGURED, circles: summary });
  }

  // 语音便签 API
  if (url.pathname === '/notes' && req.method === 'GET') {
    const circleId = url.searchParams.get('circleId') ?? 'home';
    return json(200, { notes: await listNotes(circleId) });
  }
  if (url.pathname === '/notes' && req.method === 'POST') {
    try {
      const body = JSON.parse(await readBody(req));
      const { circleId = 'home', userId, name, audio, mime, durationSec } = body;
      if (!userId || !audio || typeof audio !== 'string') return json(400, { error: 'bad_note' });
      if (audio.length > NOTE_MAX_BYTES) return json(413, { error: 'too_large' });
      if ((durationSec ?? 0) > NOTE_MAX_SECONDS + 1) return json(400, { error: 'too_long' });
      const note = {
        id: crypto.randomUUID(),
        circleId,
        userId,
        name: String(name ?? '圈友').slice(0, 24),
        audio,
        mime: String(mime ?? 'audio/aac'),
        durationSec: Math.min(Number(durationSec) || 0, NOTE_MAX_SECONDS),
        createdAt: Date.now(),
      };
      await saveNote(circleId, note);
      // 通知圈内成员有新便签(在房的人可即时听)
      broadcast(circleId, { t: 'note_added', circleId, noteId: note.id, name: note.name, durationSec: note.durationSec });
      return json(201, { id: note.id });
    } catch {
      return json(400, { error: 'bad_json' });
    }
  }
  if (url.pathname.startsWith('/notes/') && req.method === 'DELETE') {
    const id = url.pathname.slice('/notes/'.length);
    const circleId = url.searchParams.get('circleId') ?? 'home';
    await deleteNote(circleId, id);
    return json(200, { ok: true });
  }

  res.writeHead(404);
  res.end();
});

// WS 挂 / 与 /ws 两条路径(后者供反代按路径分流,见 deploy/)
const wss = new WebSocketServer({ noServer: true });
server.on('upgrade', (req, socket, head) => {
  let pathname = '/';
  try {
    pathname = new URL(req.url, 'http://x').pathname;
  } catch { /* 按默认处理 */ }
  if (pathname === '/' || pathname === '/ws') {
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
  } else {
    socket.destroy();
  }
});
wss.on('connection', handleConnection);

// 心跳:30s 无 pong 判定死连接,清理 presence
const heartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (ws._laresAlive === false) { ws.terminate(); continue; }
    ws._laresAlive = false;
    ws.ping();
  }
}, 30_000);
wss.on('connection', (ws) => {
  ws._laresAlive = true;
  ws.on('pong', () => { ws._laresAlive = true; });
});
wss.on('close', () => clearInterval(heartbeat));

server.listen(PORT, async () => {
  await loadSettings();
  console.log(`[lares] 信令服务已启动  ws://0.0.0.0:${PORT}`);
  console.log(`[lares] RTC: ${RTC_CONFIGURED ? `LiveKit 已配置 (${LIVEKIT_URL})` : '未配置(仅 presence,设置 LIVEKIT_URL/API_KEY/API_SECRET 启用)'}`);
});
