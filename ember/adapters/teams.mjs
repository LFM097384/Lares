/**
 * 隐名之约 · Microsoft Teams adapter（STUB，未实现）
 *
 * 受 Chatham House 规则启发 · 非官方 · 与 Chatham House 无隶属。
 * 可行性说明：docs/plans/chatham/04-zoom-teams.md
 *
 * 选定路径（两段）：
 *   T0 · 会议侧边栏（meetingSidePanel 标签页）+ 会议聊天 bot（Teams SDK for TypeScript，与 Node 核心同栈）。
 *        无媒体：参会者在侧边栏打字发言 -> ctx.onUtterance；规则宣读、roster、问答、review（targeted messages
 *        只发本人）、Ed25519 签名批准、离会按钮。没有媒体合规问题，可先行。
 *   T1 · 应用托管媒体侧车（C#/.NET，Microsoft.Graph.Communications.Calls.Media，Azure Windows Server VM，
 *        实例级公网 IP；Node.js 不支持实时媒体）。侧车只收 UnmixedAudioBuffer，按 ActiveSpeakerId 映射参会者，
 *        经内网 WebSocket 把每人 PCM 推给本 adapter；本 adapter 送 DashScope 流式 ASR -> ctx.onUtterance。
 *        侧车不落盘、不记录内容日志。先以组织内部自定义应用（LOB）部署。
 *   不采用：Graph 会后转写 API（会后才有、原文已存租户）；合规录制策略（管理员强制、无参与者同意）。
 *   注意：微软文档称实时媒体 bot "not recommended for AI agent scenarios"；
 *        updateRecordingStatus 条款要求持久化媒体或其派生数据前先标记 recording —— 保守默认在 B 档开始时调用。
 *        21Vianet（中国区）不可用。
 *
 * 离会模式：A 档（严格按规则，官方 FAQ 不允许 AI notetaker）不得让侧车入会；
 *   stop() 必须 (1) 让侧车挂断通话 (2) ctx.postToRoom 宣告 agent 已离开 (3) 此后不再调用任何 ctx.on* 回调。
 *
 * 阻塞性未知项：第三方 AI agent 使用媒体 API 的许可与商店通过率；k 人批准后的摘要是否触发
 *   updateRecordingStatus 义务；ActiveSpeakerId 映射稳定性；Windows VM 运维与 NuGet 三个月升级；
 *   Copilot / 原生转写同时开启时的防绕过。
 */

/**
 * @typedef {Object} AdapterCtx  与 ember/INTERFACE.md 一致
 * @property {(speakerId: string, text: string, ts: number, final: boolean) => void} onUtterance
 *   T0：侧边栏文字发言；T1：侧车 PCM -> DashScope ASR 的中间/最终结果。speakerId 为 roster id。
 * @property {(m: {id: string, name: string, aliases?: string[], org?: string, title?: string}) => void} onMemberJoin
 *   会议参会者事件 / participants 通知；AAD 对象 id 只在内存映射。
 * @property {(id: string) => void} onMemberLeave
 * @property {(msg: any) => void} postToRoom
 *   室内消息：会议聊天 bot 消息或侧边栏推送；个人 review 卡片用 targeted messages。永不出门。
 * @property {(text: string) => void} postOutward
 *   唯一出门渠道；只允许传入 session.released(draftId).text。
 * @property {() => Array<{id: string, name: string}>} roster
 */

export const name = 'teams';

/**
 * 启动：校验 B 档 -> T0 连接侧边栏/聊天 bot；T1 另行指示媒体侧车入会（必要时先 updateRecordingStatus），
 * 订阅侧车 WebSocket 的每人 PCM 与参会者事件，映射到 ctx。
 * @param {AdapterCtx} ctx
 * @returns {Promise<void>}
 */
export async function start(ctx) { // eslint-disable-line no-unused-vars
  throw new Error('teams adapter: not implemented (see docs/plans/chatham/04-zoom-teams.md)');
}

/**
 * 停止 / 离会：侧车挂断（若曾标记 recording 则先结束并置 notRecording），postToRoom 宣告离开，解除回调。
 * @returns {Promise<void>}
 */
export async function stop() {
  throw new Error('teams adapter: not implemented (see docs/plans/chatham/04-zoom-teams.md)');
}

/**
 * Ember port(../PORT.md)形状的工厂 —— 真实现时由它把平台事件喂给 createEmber({ port })。
 * 映射草案:参与者加入 / 离开 → 'joined' / 'left';每人音频(或转写)→ 'audio';侧边栏消息 → 'message';
 * port.send → 侧边栏;port.notifyHost({type:'active'}) → 平台侧「AI 在场」提示。
 * @returns {import('../port.mjs').EmberPort}
 */
export function createPort(opts = {}) { // eslint-disable-line no-unused-vars
  throw new Error('teams adapter: createPort not implemented (see ember/PORT.md, docs/plans/chatham/04-zoom-teams.md)');
}

export default { name, start, stop, createPort };
