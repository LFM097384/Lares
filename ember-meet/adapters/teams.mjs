// ember-meet · Microsoft Teams 网页版 adapter:模拟一个匿名访客。
// 进会流程(和真人一样):打开会议链接 → 「在此浏览器上继续」→ 填名字「炉灵」→ 关摄像头、关麦克风 → 「立即加入」
// → 大厅等组织者放行 → 进会。进会后:更多 → 语言和语音 → 打开实时字幕;打开聊天面板。
// 所有选择器都在 teams-selectors.mjs;这里只有流程。
import * as S from './teams-selectors.mjs';
import { AdapterError, ensureProbe, sleep, firstVisible, anyVisible, clickFirst, switchState, waitVisible } from './util.mjs';
import { teamsOf } from '../urls.mjs';

/// 预加入页上把一个开关调到「关」(want=true 时调到「开」)。返回 'off'|'on'(本来就是)| 'clicked' | 'absent' | 'unknown'
async function turnOff(page, selectors, log, what, want = false) {
  const loc = await firstVisible(page, selectors);
  if (!loc) return 'absent';
  const st = await switchState(loc);
  if (st === want) return want ? 'on' : 'off';
  if (st === null) { log(`teams: ${what} 开关状态看不出,不动它`); return 'unknown'; }
  try { await loc.click({ timeout: 3000 }); } catch { return 'unknown'; }
  await sleep(250);
  const after = await switchState(loc);
  return after === want ? 'clicked' : 'unknown';
}

async function fillName(page, name) {
  const input = await firstVisible(page, S.NAME_INPUT);
  if (!input) return false;
  await input.click({ timeout: 3000 }).catch(() => {});
  await input.fill('');
  await input.fill(name);
  return (await input.inputValue().catch(() => '')) === name;
}

export const teamsAdapter = Object.freeze({
  name: 'teams',
  label: 'Teams 会议',
  implemented: true,
  selectors: S,

  matches(url) { try { return Boolean(teamsOf(url)); } catch { return false; } },

  /**
   * @param {import('playwright').Page} page
   * @param {{url:string, displayName:string, log?:Function, timeoutMs?:number, lobbyTimeoutMs?:number, onState?:Function, stepMs?:number, micOn?:boolean}} o
   */
  async join(page, { url, displayName, log = () => {}, timeoutMs = 90_000, lobbyTimeoutMs = 15 * 60_000, onState = () => {}, stepMs = 300, micOn = false }) {
    onState('opening');
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60_000 });
    const t0 = Date.now();
    let named = false;
    let media = false;
    let joinClicked = false;
    let lobbySince = 0;
    // 状态机式轮询:Teams 的各页面是同一个单页应用里换内容,顺序也随版本变 —— 每轮看「现在屏幕上有什么」再做对应的事
    for (;;) {
      await ensureProbe(page);
      if (await anyVisible(page, S.DENIED_TEXT)) throw new AdapterError('denied', '组织者拒绝了入会请求');
      if (await anyVisible(page, S.HANGUP)) { onState('in-meeting'); log('teams: 已进会'); return; }
      if (await anyVisible(page, S.NOT_FOUND_TEXT)) throw new AdapterError('not_found', '找不到这个会议(链接错、会议已结束或已删除)');
    if (await anyVisible(page, S.ENDED_TEXT)) throw new AdapterError('ended', '会议已结束或已被移出');
      if (await anyVisible(page, S.LOBBY_TEXT)) {
        if (!lobbySince) { lobbySince = Date.now(); onState('lobby'); log('teams: 在大厅等待组织者放行'); }
        if (Date.now() - lobbySince > lobbyTimeoutMs) throw new AdapterError('lobby_timeout', '大厅等待超时,没人放行');
        await sleep(stepMs * 3);
        continue;
      }
      if (!joinClicked && await clickFirst(page, S.CONTINUE_WITHOUT_MEDIA)) { log('teams: 不使用音视频继续'); continue; }
      if (!joinClicked && await clickFirst(page, S.LAUNCHER_WEB)) { onState('launcher'); log('teams: 选择在此浏览器上继续'); await sleep(stepMs); continue; }
      const joinBtn = joinClicked ? null : await firstVisible(page, S.JOIN_BUTTON);
      if (joinBtn) {
        onState('prejoin');
        if (!named) { named = await fillName(page, displayName); if (named) log('teams: 已填写显示名'); }
        if (!media) {
          const cam = await turnOff(page, S.CAMERA_TOGGLE, log, '摄像头');
          const mic = await turnOff(page, S.MIC_TOGGLE, log, '麦克风', micOn); // 炉灵永远关麦;只有 sim speaker 开麦
          log(`teams: 摄像头=${cam} 麦克风=${mic}`);
          media = true;
        }
        if (!named && await firstVisible(page, S.NAME_INPUT)) { await sleep(stepMs); continue; }
        try { await joinBtn.click({ timeout: 5000 }); joinClicked = true; onState('joining'); log('teams: 已点「立即加入」'); } catch { /* 按钮还没启用 */ }
        await sleep(stepMs);
        continue;
      }
      if (!lobbySince && Date.now() - t0 > timeoutMs) throw new AdapterError('join_timeout', joinClicked ? '点了加入但没进会也没进大厅' : '没找到 Teams 的预加入页(链接失效 / 需要登录 / 页面改版?)');
      await sleep(stepMs);
    }
  },

  /// 打开实时字幕。字幕已经在显示 → true;组织者禁用 / 菜单找不到 → false
  async enableCaptions(page, { log = () => {}, stepMs = 300 } = {}) {
    await ensureProbe(page);
    const has = async () => (await page.evaluate((sel) => window.__emberMeet.captions(sel).present, S.CAPTION).catch(() => false));
    if (await has()) return true;
    if (!await clickFirst(page, S.MORE_BUTTON, { timeoutMs: 5000 })) { log('teams: 找不到「更多」按钮'); return false; }
    await sleep(stepMs);
    if (!await firstVisible(page, S.CAPTIONS_ON)) await clickFirst(page, S.LANGUAGE_MENU, { timeoutMs: 3000 });
    await sleep(stepMs);
    if (!await clickFirst(page, S.CAPTIONS_ON, { timeoutMs: 3000 })) { log('teams: 菜单里没有「打开实时字幕」(组织者可能禁用了字幕)'); await page.keyboard.press('Escape').catch(() => {}); return false; }
    await sleep(stepMs);
    await clickFirst(page, S.CAPTIONS_LANGUAGE_CONFIRM, { timeoutMs: 1500 });
    for (let i = 0; i < 20; i++) { if (await has()) return true; await sleep(stepMs); }
    // 没人说话时 Teams 可能还没渲染字幕容器:菜单点成功就当已开
    return true;
  },

  async openChat(page, { log = () => {} } = {}) {
    await ensureProbe(page);
    // 面板收起时列表节点可能还在 DOM 里:以「输入框可见」为准
    const present = async () => Boolean(await firstVisible(page, [S.CHAT.compose]));
    if (await present()) return true;
    if (!await clickFirst(page, S.CHAT_BUTTON, { timeoutMs: 5000 })) { log('teams: 找不到聊天按钮(组织者可能关闭了会议聊天)'); return false; }
    for (let i = 0; i < 20; i++) { if (await present()) return true; await sleep(250); }
    return false;
  },

  async readCaptions(page) {
    await ensureProbe(page);
    return page.evaluate((sel) => window.__emberMeet.captions(sel), S.CAPTION).catch(() => ({ present: false, items: [] }));
  },

  async readChat(page) {
    await ensureProbe(page);
    return page.evaluate((sel) => window.__emberMeet.chat(sel), S.CHAT).catch(() => ({ present: false, items: [] }));
  },

  /// 往会议聊天发一条。多行:Shift+Enter 换行,Enter 发送(Teams 编辑器的行为)
  async sendChat(page, text) {
    let box = await firstVisible(page, [S.CHAT.compose]);
    if (!box) { await teamsAdapter.openChat(page); box = await waitVisible(page, [S.CHAT.compose], 5000); }
    if (!box) throw new AdapterError('no_chat', '找不到聊天输入框');
    await box.click({ timeout: 3000 });
    const lines = String(text).split('\n');
    for (let i = 0; i < lines.length; i++) {
      if (i) await page.keyboard.press('Shift+Enter');
      if (lines[i]) await page.keyboard.insertText(lines[i]);
    }
    await page.keyboard.press('Enter');
  },

  async participants(page) {
    await ensureProbe(page);
    return page.evaluate((sel) => window.__emberMeet.roster(sel), S.ROSTER).catch(() => []);
  },

  async inMeeting(page) {
    try {
      if (page.isClosed()) return 'ended';
      if (await anyVisible(page, S.HANGUP)) return 'in';
      if (await anyVisible(page, S.ENDED_TEXT)) return 'ended';
      return 'unknown';
    } catch { return 'unknown'; }
  },

  async leave(page) {
    try {
      if (page.isClosed()) return;
      if (await clickFirst(page, S.HANGUP)) {
        await sleep(400);
        await clickFirst(page, S.HANGUP_CONFIRM); // 有确认菜单时只选「离开」,绝不选「结束会议」
      }
    } catch { /* 离会尽力而为 */ }
  },
});
