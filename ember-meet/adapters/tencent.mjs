// ember-meet · 腾讯会议网页版 adapter —— **未实现**(占位,形状与 teams.mjs 一致)。
// 路线(README「路线图」):腾讯会议网页版入会通常要求登录(微信 / 手机号)或跳转客户端;能否匿名入会、字幕是否在 DOM 里都待核实。
import { tencentOf } from '../urls.mjs';

const nope = (what) => async () => { throw new Error(`ember-meet: Tencent Meeting adapter not implemented (${what})`); };

export const tencentAdapter = Object.freeze({
  name: 'tencent',
  label: '腾讯会议',
  implemented: false,
  matches(url) { try { return Boolean(tencentOf(url)); } catch { return true; } },
  join: nope('join'),
  enableCaptions: nope('enableCaptions'),
  readCaptions: nope('readCaptions'),
  readChat: nope('readChat'),
  sendChat: nope('sendChat'),
  participants: nope('participants'),
  leave: nope('leave'),
  inMeeting: nope('inMeeting'),
});
