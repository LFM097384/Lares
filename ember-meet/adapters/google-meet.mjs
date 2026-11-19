// ember-meet · Google Meet adapter —— **未实现**(占位,形状与 teams.mjs 一致)。
// 路线(README「路线图」):Meet 访客通常要登录 Google 账号才能「请求加入」;匿名访客在很多组织里被禁。
// 实现时:复用 driver.mjs / captions.mjs / chat.mjs;字幕 DOM 在 Meet 里是 jsname 属性族,另写一份 selectors。
import { googleMeetOf } from '../urls.mjs';

const nope = (what) => async () => { throw new Error(`ember-meet: Google Meet adapter not implemented (${what})`); };

export const googleMeetAdapter = Object.freeze({
  name: 'google-meet',
  label: 'Google Meet 会议',
  implemented: false,
  matches(url) { try { return Boolean(googleMeetOf(url)); } catch { return true; } },
  join: nope('join'),
  enableCaptions: nope('enableCaptions'),
  readCaptions: nope('readCaptions'),
  readChat: nope('readChat'),
  sendChat: nope('sendChat'),
  participants: nope('participants'),
  leave: nope('leave'),
  inMeeting: nope('inMeeting'),
});
