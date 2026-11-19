// ember-meet · 平台 adapter 注册表与接口约定。
//
// 一个 adapter 把「模拟真人在某个会议网页里的操作」封装成固定的几步。driver.mjs 只认这个接口,不认平台:
//
//   name: string                        'teams' | 'google-meet' | 'tencent'
//   label: string                       中文显示名(公告用)
//   matches(url) → boolean              这个链接归不归我
//   join(page, {url, displayName, log, timeoutMs, onState}) → Promise<void>
//                                       打开链接 → 选「在浏览器继续」→ 填名字 → 关摄像头和麦克风 → 加入 → 大厅等放行。
//                                       进会后返回;被拒 / 超时 → 抛 AdapterError(code)。onState(s) 报告 lobby 等状态。
//   enableCaptions(page, {log}) → Promise<boolean>     打开实时字幕;平台不允许 / 找不到 → false(不抛)
//   readCaptions(page) → Promise<{present, items:[{key, speaker, text}]}>   字幕区快照(未去重,driver 交给 CaptionTracker)
//   readChat(page) → Promise<{present, items:[{key, author, text, mine}]}>  聊天列表快照
//   sendChat(page, text) → Promise<void>
//   participants(page) → Promise<string[]>             参会者显示名(面板开着时才可靠;读不到返回 [])
//   leave(page) → Promise<void>                        点挂断;幂等,出错不抛
//   inMeeting(page) → Promise<'in'|'ended'|'unknown'>  进会后定时检查:被移出 / 会议结束 → 'ended'
import { teamsAdapter } from './teams.mjs';
import { googleMeetAdapter } from './google-meet.mjs';
import { tencentAdapter } from './tencent.mjs';
export { AdapterError } from './util.mjs';

export const ADAPTERS = Object.freeze([teamsAdapter, googleMeetAdapter, tencentAdapter]);
export const REQUIRED = Object.freeze(['matches', 'join', 'enableCaptions', 'readCaptions', 'readChat', 'sendChat', 'participants', 'leave', 'inMeeting']);

export function checkAdapter(a) {
  const missing = REQUIRED.filter((k) => typeof a?.[k] !== 'function');
  if (missing.length || typeof a?.name !== 'string') throw new TypeError(`ember-meet adapter ${a?.name ?? '?'} missing ${missing.join(', ') || 'name'}`);
  return a;
}

export function adapterFor(url) {
  return ADAPTERS.find((a) => { try { return a.matches(url); } catch { return false; } }) ?? null;
}

export const adapterByName = (name) => ADAPTERS.find((a) => a.name === name) ?? null;
