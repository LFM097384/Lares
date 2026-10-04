// 成员资料 profile_set:纯函数单测 + 端到端(起服务、两人进房、改资料)
// 运行:node test/profile.mjs
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import WebSocket from 'ws';
import {
  stripControl, capGraphemes, cleanName, cleanBio, cleanEmoji, profileSetAllowed,
  PROFILE_NAME_MAX, PROFILE_BIO_MAX,
} from '../src/profile.js';

const PORT = 18993;
let fail = 0;
const check = (name, cond, extra = '') => {
  console.log(`${cond ? '✓' : '✗'} ${name}${cond ? '' : ` ${extra}`}`);
  if (!cond) fail++;
};
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const glen = (s) => [...new Intl.Segmenter('und', { granularity: 'grapheme' }).segment(s)].length;

// ── 单测 ──
check('stripControl 去 \\u0000', stripControl('a\u0000b') === 'ab');
check('stripControl 换行变空格并折叠', stripControl('  a\n\n b\tc  ') === 'a b c');
check('stripControl 去 bidi 覆盖 \\u202E', stripControl('\u202Eabc\u2066') === 'abc');
check('stripControl 去零宽空格/BOM,保留 ZWJ', stripControl('a\u200B\uFEFF\u200Db') === 'a\u200Db');
check('stripControl 去 C1', stripControl('a\u0085\u009Fb') === 'ab');
check('常量', PROFILE_NAME_MAX === 24 && PROFILE_BIO_MAX === 40);
const cjk = '炉'.repeat(30);
check('cleanName CJK 截到 24 字', cleanName(cjk) === '炉'.repeat(24));
const fam = '👨‍👩‍👧';
const nameZwj = cleanName(fam.repeat(30));
check('cleanName ZWJ emoji 按字形截 24 个', glen(nameZwj) === 24 && nameZwj === fam.repeat(24));
check('cleanBio 截到 40 字形', cleanBio('字'.repeat(50)) === '字'.repeat(40) && glen(cleanBio(fam.repeat(41))) === 40);
check('capGraphemes 短串原样', capGraphemes('abc', 5) === 'abc');
check('cleanName 非字符串 → null', cleanName(42) === null && cleanName(undefined) === null);
check('cleanName 只剩控制符 → null', cleanName('\u0000\n\u202E ') === null);
check('cleanBio 空串清空', cleanBio('') === '');
for (const e of ['🔥', fam, '🇨🇳']) check(`cleanEmoji 接受 ${e}`, cleanEmoji(e) === e);
for (const e of ['ab', '🔥🔥', 'a']) check(`cleanEmoji 拒绝 ${e}`, cleanEmoji(e) === null);
check('cleanEmoji 空串 = 清空', cleanEmoji('') === '');
check('cleanEmoji 非字符串 → null', cleanEmoji(5) === null);
check('profileSetAllowed 拒 u_ai_ / bot:', !profileSetAllowed('u_ai_x') && !profileSetAllowed('bot:x') && profileSetAllowed('u_a'));

// ── 端到端 ──
const base = { ...process.env };
for (const k of ['LARES_AUTH_MODE', 'LARES_AUTH_TOKEN', 'LARES_CIRCLE_PASSCODE',
  'LARES_CIRCLE_PASSCODES', 'LARES_ALLOWED_ORIGIN', 'LARES_AUTH_NONCE_TTL_MS']) delete base[k];
const server = spawn(process.execPath, ['src/index.js'], {
  env: { ...base, LARES_PORT: String(PORT), LARES_DATA_DIR: mkdtempSync(path.join(tmpdir(), 'lares-test-')) },
  stdio: 'inherit',
});

function client() {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
  const inbox = [];
  const waiters = [];
  ws.on('error', () => {});
  ws.on('message', (raw) => {
    const msg = JSON.parse(raw);
    inbox.push(msg);
    for (let i = waiters.length - 1; i >= 0; i--) {
      if (waiters[i].pred(msg)) { waiters[i].resolve(msg); waiters.splice(i, 1); }
    }
  });
  const opened = new Promise((r, j) => { ws.on('open', r); ws.on('error', j); });
  return {
    ws, inbox, opened,
    send: (m) => ws.send(JSON.stringify(m)),
    clear: () => inbox.splice(0),
    waitFor: (pred, ms = 3000) => new Promise((resolve, reject) => {
      const hit = inbox.find(pred);
      if (hit) return resolve(hit);
      waiters.push({ pred, resolve });
      setTimeout(() => reject(new Error('timeout waiting message')), ms);
    }),
  };
}

async function hello(c, hm) {
  await c.opened;
  c.send({ t: 'hello', platform: 'test', ...hm });
  await c.waitFor((m) => m.t === 'welcome');
}

try {
  for (let i = 0; i < 100; i++) {
    try { if ((await fetch(`http://127.0.0.1:${PORT}/health`)).ok) break; } catch { /* 未就绪 */ }
    await wait(100);
  }

  // hello 前 profile_set
  const z = client();
  await z.opened;
  z.send({ t: 'profile_set', name: 'x' });
  const ez = await z.waitFor((m) => m.t === 'profile_error');
  check('hello 前 → say_hello_first', ez.reason === 'say_hello_first');
  z.ws.close();

  const a = client();
  const b = client();
  await hello(a, { userId: 'u_pa', deviceId: 'd_pa', name: '阿伟\u202E' });
  await hello(b, { userId: 'u_pb', deviceId: 'd_pb', name: '小敏' });
  a.send({ t: 'join', circleId: 'prof' });
  const roomA = await a.waitFor((m) => m.t === 'room');
  check('hello 名字被清洗', roomA.members[0].name === '阿伟');
  check('快照带 joinedAt', typeof roomA.members[0].joinedAt === 'number' && roomA.members[0].joinedAt > 0);
  check('未设置时快照不带 emoji/bio', !('emoji' in roomA.members[0]) && !('bio' in roomA.members[0]));
  b.send({ t: 'join', circleId: 'prof' });
  await b.waitFor((m) => m.t === 'room');
  await a.waitFor((m) => m.t === 'member_joined');

  const lobby = client();
  await hello(lobby, { userId: 'u_pl', deviceId: 'd_pl', name: '路人' });
  lobby.clear();

  a.send({ t: 'profile_set', name: '阿伟同学', emoji: '🔥', bio: '今天也在 ✨\n写代码' });
  const upd = await b.waitFor((m) => m.t === 'member_updated' && m.member.userId === 'u_pa');
  check('B 收到 member_updated 新资料',
    upd.member.name === '阿伟同学' && upd.member.emoji === '🔥' && upd.member.bio === '今天也在 ✨ 写代码',
    JSON.stringify(upd.member));
  const ok = await a.waitFor((m) => m.t === 'profile_ok');
  check('A 收到 profile_ok', ok.name === '阿伟同学' && ok.emoji === '🔥' && ok.bio === '今天也在 ✨ 写代码');
  const sum = await lobby.waitFor((m) => m.t === 'circle_summary' && m.circleId === 'prof' && m.names.includes('阿伟同学'));
  check('大厅摘要含新名字与 emojis', Array.isArray(sum.emojis) && sum.emojis.length === sum.names.length
    && sum.emojis[sum.names.indexOf('阿伟同学')] === '🔥' && sum.emojis[sum.names.indexOf('小敏')] === null,
  JSON.stringify(sum));

  // 无效 emoji
  a.clear();
  a.send({ t: 'profile_set', emoji: '🔥🔥', name: '不该生效' });
  const inv = await a.waitFor((m) => m.t === 'profile_error');
  check('无效 emoji → invalid', inv.reason === 'invalid');
  a.send({ t: 'profile_set', bio: 5 });
  await wait(100);
  check('字段类型错 → invalid', a.inbox.filter((m) => m.t === 'profile_error' && m.reason === 'invalid').length === 2);

  // 清空 bio
  b.clear();
  a.send({ t: 'profile_set', bio: '' });
  const cleared = await b.waitFor((m) => m.t === 'member_updated' && m.member.userId === 'u_pa');
  check('bio 清空后快照不带 bio', !('bio' in cleared.member) && cleared.member.emoji === '🔥' && cleared.member.name === '阿伟同学');

  // 限流:已用 1(成功)+2(invalid 也耗令牌)+1 = 4 次;再发到第 11 次应被拒
  a.clear();
  for (let i = 0; i < 6; i++) a.send({ t: 'profile_set', name: `名${i}` });
  a.send({ t: 'profile_set', name: '第十一' });
  const rl = await a.waitFor((m) => m.t === 'profile_error' && m.reason === 'rate_limited');
  check('第 11 次 → rate_limited 带 retryMs', typeof rl.retryMs === 'number' && rl.retryMs > 0);
  check('前 10 次都成功', a.inbox.filter((m) => m.t === 'profile_ok' && m.name.startsWith('名')).length === 6
    && !a.inbox.some((m) => m.t === 'profile_ok' && m.name === '第十一'));

  // 重连 hello 带 emoji/bio → 房间快照可见
  b.ws.close();
  await wait(200);
  const b2 = client();
  await hello(b2, { userId: 'u_pb', deviceId: 'd_pb', name: '小敏', emoji: '🇨🇳', bio: '回来了' });
  b2.send({ t: 'join', circleId: 'prof' });
  const room2 = await b2.waitFor((m) => m.t === 'room');
  const meB = room2.members.find((m) => m.userId === 'u_pb');
  check('重连 hello 的 emoji/bio 出现在快照', meB?.emoji === '🇨🇳' && meB?.bio === '回来了', JSON.stringify(meB));

  // hello 无效 emoji:不失败,只是不设
  const d = client();
  await hello(d, { userId: 'u_pd', deviceId: 'd_pd', name: 'D', emoji: 'abc' });
  d.send({ t: 'join', circleId: 'prof' });
  const room3 = await d.waitFor((m) => m.t === 'room');
  check('hello 无效 emoji 被忽略', !('emoji' in room3.members.find((m) => m.userId === 'u_pd')));

  for (const c of [a, b2, d, lobby]) c.ws.close();
} catch (e) {
  console.error(e);
  fail++;
} finally {
  server.kill();
}
console.log(fail ? `\n${fail} 项失败` : '\n全部通过');
process.exit(fail ? 1 : 0);
