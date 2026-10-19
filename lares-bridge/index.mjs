// lares-bridge · Lares 接入层的公共出口。灶语(hearthvoice-lares)与炉灵(ember-lares)都只从这里 import。
// 内容:LaresRoom(信令 HMAC 挑战应答 / AI 成员凭证 aiAuth / LiveKit 进房 / E2EE 密钥派生 / data topic 收发 / 音轨发布),
// 线协议常量与帧编解码,房间音频格式,以及 npm 依赖解析(ws / hash-wasm / rtc-node 来自 server/node_modules)。
// 它不 import server/ 下任何源码;server/ 也不 import 它。

export {
  CHAT_TOPIC, CAPTION_TOPIC, AI_STATE_TOPIC,
  authVerifier, e2eeKeyHex, encodeChatFrame, decodeChatFrame,
  defaultAiUserId, isLaresHuman, loadRtcNode,
  AuthError, CircleGoneError, E2eeRequiredError,
  LaresRoom,
} from './room.mjs';
export { ROOM_RATE, FRAME_SAMPLES, monoOf, framesOf } from './audio.mjs';
export { WebSocket, argon2id, importDep, FALLBACK_ANCHORS } from './deps.mjs';
