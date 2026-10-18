/**
 * 隐名之约 · Zoom adapter（STUB，未实现）
 *
 * 受 Chatham House 规则启发 · 非官方 · 与 Chatham House 无隶属。
 * 可行性说明：docs/plans/chatham/04-zoom-teams.md
 *
 * 选定路径：Zoom RTMS（Realtime Media Streams）+ Zoom App 侧边栏
 *   - 不使用 Meeting SDK 原始数据 bot：Zoom 官方政策称 Meeting SDK
 *     "does not support bots or AI notetakers"，AI 场景须用 RTMS。
 *   - 侧边栏（Zoom Apps SDK）负责：规则宣读、A/B 档选择、roster 确认、
 *     室内问答、草稿 review、Ed25519 签名批准、离会按钮；B 档时调
 *     startRTMS() 启动流（主持人 Allow/Deny）。
 *   - 服务器侧订阅 RTMS WebSocket：
 *       MEDIA_DATA_TRANSCRIPT (17)  -> ctx.onUtterance  （带说话人转写，src_language=简体中文）
 *       PARTICIPANT_JOIN (3)        -> ctx.onMemberJoin
 *       PARTICIPANT_LEAVE (4)       -> ctx.onMemberLeave
 *       任一 STOP_BC_*（STREAM_REVOKED / HOST_DISABLED_APP / MEETING_ENDED…） -> 调用方 session.end()
 *     可选 Z2：改订阅每人 L16 16kHz PCM（MEDIA_DATA_AUDIO 14，AUDIO_MULTI_STREAMS），自备 DashScope ASR。
 *   - 平台会强制显示 "The content of this meeting is being sent to one or more apps."，
 *     它不能替代我们自己的入场规则宣读确认。
 *   - 原文只进内存（Session 环形缓冲），不落盘、不写内容日志；Zoom 侧启动时可能缓冲 ≤60s 音频，界面须如实说明。
 *
 * 离会模式：A 档（严格按规则，官方 FAQ 不允许 AI notetaker）不得启动流；
 *   stop() 必须 (1) 关闭 RTMS 流 (2) ctx.postToRoom 宣告 agent 已离开 (3) 此后不再调用任何 ctx.on* 回调。
 *
 * 阻塞性未知项：RTMS 转写延迟与 final 语义；是否依赖会议字幕设置；Developer Pack 计费；
 *   Marketplace 对境内云 LLM 子处理方的态度；能否检测 AI Companion 开启；Zoom App 能否向会议聊天发消息。
 */

/**
 * @typedef {Object} AdapterCtx  与 ember/INTERFACE.md 一致
 * @property {(speakerId: string, text: string, ts: number, final: boolean) => void} onUtterance
 *   RTMS 转写一条 -> speakerId 为 roster id（RTMS user_id 只在内存映射，不外传）。
 * @property {(m: {id: string, name: string, aliases?: string[], org?: string, title?: string}) => void} onMemberJoin
 *   RTMS PARTICIPANT_JOIN；name 取自 user_name，仅在内存。
 * @property {(id: string) => void} onMemberLeave
 *   RTMS PARTICIPANT_LEAVE。
 * @property {(msg: any) => void} postToRoom
 *   室内消息：推送到 Zoom App 侧边栏（或会议聊天，待确认）。永不出门。
 * @property {(text: string) => void} postOutward
 *   唯一出门渠道；只允许传入 session.released(draftId).text。
 * @property {() => Array<{id: string, name: string}>} roster
 *   侧边栏确认后的名单（仅内存）。
 */

export const name = 'zoom';

/**
 * 启动：校验 B 档 -> 等侧边栏 startRTMS() 触发的 meeting.rtms_started webhook
 * -> 建立信令/媒体 WebSocket 握手（transcript, src_language=简体中文）-> 映射事件到 ctx。
 * @param {AdapterCtx} ctx
 * @returns {Promise<void>}
 */
export async function start(ctx) { // eslint-disable-line no-unused-vars
  throw new Error('zoom adapter: not implemented (see docs/plans/chatham/04-zoom-teams.md)');
}

/**
 * 停止 / 离会：关闭 RTMS 流（STREAM_CLOSE_REQ 21），postToRoom 宣告离开，解除所有回调。
 * @returns {Promise<void>}
 */
export async function stop() {
  throw new Error('zoom adapter: not implemented (see docs/plans/chatham/04-zoom-teams.md)');
}

/**
 * Ember port(../PORT.md)形状的工厂 —— 真实现时由它把平台事件喂给 createEmber({ port })。
 * 映射草案:参与者加入 / 离开 → 'joined' / 'left';每人音频(或转写)→ 'audio';侧边栏消息 → 'message';
 * port.send → 侧边栏;port.notifyHost({type:'active'}) → 平台侧「AI 在场」提示。
 * @returns {import('../port.mjs').EmberPort}
 */
export function createPort(opts = {}) { // eslint-disable-line no-unused-vars
  throw new Error('zoom adapter: createPort not implemented (see ember/PORT.md, docs/plans/chatham/04-zoom-teams.md)');
}

export default { name, start, stop, createPort };
