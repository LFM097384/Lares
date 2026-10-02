// 服务器 → LiveKit 房间的数据包(RoomService.SendData,Twirp JSON)。
//
// 为什么自己发 Twirp 而不是 RoomServiceClient.sendData:SDK 的请求体由 protobuf-es 生成,
// 字段名与重试/区域回退逻辑都藏在里面;机器人消息是**防伪造**的关键路径
// (客户端只认「participant == null」的帧,见 docs/plans/transcript-bot-contract.md §1/§2),
// 线上发出去的到底是什么必须一眼看得清、测试里能逐字段核对。
//
// 鉴权:HS256 JWT,iss = API key,video grant {room, roomAdmin:true} —— 只对这一个房间有效。

import crypto from 'node:crypto';
import { AccessToken } from 'livekit-server-sdk';

export const CHAT_TOPIC = 'lares.chat';
export const CAPTION_TOPIC = 'lares.cap';

/// ws(s):// → http(s)://,去掉末尾斜杠
export function httpBase(url) {
  return String(url).replace(/^ws(s?):\/\//i, 'http$1://').replace(/\/+$/, '');
}

/// 聊天帧:4 字节大端 header 长度 + UTF-8 JSON header (+ 空 payload)。
/// 与 app/lib/src/chat/chat_envelope.dart 的 encodeFrame 逐字节一致。
export function encodeChatFrame(header, payload = Buffer.alloc(0)) {
  const h = Buffer.from(JSON.stringify(header), 'utf8');
  const len = Buffer.alloc(4);
  len.writeUInt32BE(h.length, 0);
  return Buffer.concat([len, h, payload]);
}

export function decodeChatFrame(buf) {
  const b = Buffer.from(buf);
  if (b.length < 4) return null;
  const n = b.readUInt32BE(0);
  if (n === 0 || n > b.length - 4) return null;
  try {
    return { header: JSON.parse(b.subarray(4, 4 + n).toString('utf8')), payload: b.subarray(4 + n) };
  } catch {
    return null;
  }
}

export function createSendData({ apiUrl, apiKey, apiSecret, timeoutMs = 10_000 }) {
  const base = apiUrl ? httpBase(apiUrl) : '';

  async function adminJwt(room) {
    const at = new AccessToken(apiKey, apiSecret, { ttl: '5m' });
    at.addGrant({ room, roomAdmin: true });
    return at.toJwt();
  }

  /// 发一包。data: Buffer/Uint8Array。失败抛错(调用方转成 502)。
  async function sendData(room, data, topic) {
    if (!base || !apiKey || !apiSecret) throw new Error('livekit_not_configured');
    const body = {
      room,
      data: Buffer.from(data).toString('base64'),
      kind: 'RELIABLE',
      topic,
      destination_identities: [],
      // LiveKit 用 nonce 去重(SDK 也每次随机 16 字节)
      nonce: crypto.randomBytes(16).toString('base64'),
    };
    const res = await fetch(`${base}/twirp/livekit.RoomService/SendData`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${await adminJwt(room)}`,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!res.ok) {
      let detail = '';
      try { detail = (await res.text()).slice(0, 200); } catch { /* 无所谓 */ }
      throw new Error(`SendData HTTP ${res.status} ${detail}`);
    }
    try { await res.arrayBuffer(); } catch { /* 读空即可 */ }
  }

  return { sendData, adminJwt };
}
