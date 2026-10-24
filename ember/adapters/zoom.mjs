/**
 * 隐名之约 · Zoom adapter —— 已实现,搬到 ../../ember-zoom/(与 ember-lares 同构的平台插件)。
 *
 *   ember-zoom/webhook.mjs      x-zm-signature 校验、endpoint.url_validation、meeting.rtms_* 分发
 *   ember-zoom/rtms_client.mjs  纯 ws 的 RTMS 客户端(信令 / 媒体握手、心跳、重连)
 *   ember-zoom/port.mjs         Ember port(../PORT.md):RTMS 转写 → 'transcript',侧边栏 hub → 'message'
 *   ember-zoom/sidebar/         Zoom App 侧边栏(规则宣读、邀请 / 离开、问答、k-of-n 签名放行、记忆撤回)
 *   ember-zoom/index.mjs        CLI + webhook / 侧边栏服务器,每条 RTMS 流一个 Ember 会话
 *
 * 这里不再 re-export:ember 本体保持零 npm 依赖、不反向依赖平台插件。
 */
export const name = 'zoom';
export const MOVED_TO = 'ember-zoom/';
const moved = () => { throw new Error('zoom adapter moved to ember-zoom/ (import ../../ember-zoom/port.mjs or run node ember-zoom/index.mjs)'); };
export const start = moved;
export const stop = moved;
export const createPort = moved;
export default { name, MOVED_TO, start, stop, createPort };
