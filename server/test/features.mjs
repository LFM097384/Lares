// 功能开关 + 用途预设 端到端验证。契约:docs/plans/features-purpose-contract.md §1-§3。
//
// 纯函数(用途校验 / 分享码)直接 import;其余起真实服务端进程,只看线上收发与磁盘。
// 用法:node test/features.mjs     (DEBUG=1 显示服务端 stderr)

import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { mkdtempSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import {
  makeChecker, boot, waitHealth, stop, connect, join, registerCircle, v2Auth, v1Auth, ownerReply,
} from './lib/harness.mjs';
import { validatePurpose, BUILTIN_PURPOSES, encodePurposeCode, decodePurposeCode } from '../src/purpose.js';
import { validateManifest } from '../src/plugins.js';

const PORT = 18990;
const GLOBAL_PASS = 'feat-global-' + randomBytes(4).toString('hex');
const PASSCODE = 'feat-pass-' + randomBytes(4).toString('hex');
const T = makeChecker();
const { check } = T;
const BASE = `http://127.0.0.1:${PORT}`;
const ALL_KEYS = ['captions', 'transcript', 'voiceNotes', 'map', 'recording', 'plugins', 'focus', 'p2p', 'devTools'];

const goodManifest = (over = {}) => ({
  id: 'com.example.hello', name: 'Hello', version: '1.0.0', author: 'Example', permissions: ['circle:read'], ...over,
});
const customPurpose = (over = {}) => ({
  v: 1, id: 'study-hall', name: '自习室', icon: '📚', description: '一起专注',
  features: { focus: true, captions: false },
  plugins: [{ id: 'lares.focus', enabled: true, config: { focusMin: 50, breakMin: 10 } }],
  settings: { transcript: false, knockRequired: false, e2eeWarning: false },
  ...over,
});

function unitTests() {
  console.log('\n[用途校验(纯函数)]');
  for (const k of Object.keys(BUILTIN_PURPOSES)) check(validatePurpose(BUILTIN_PURPOSES[k]).ok, `内置用途 ${k} 通过`);
  const good = validatePurpose(customPurpose());
  check(good.ok && good.purpose.plugins[0].enabled === true && good.purpose.v === 1, '合法自定义用途通过', good);
  const bad = (p) => validatePurpose(p);
  check(bad(customPurpose({ extra: 1 })).detail === 'extra:unknown_key', '未知顶层键 -> detail', bad(customPurpose({ extra: 1 })));
  check(bad(customPurpose({ features: { teleport: true } })).detail === 'features.teleport:unknown_key', '未知功能键');
  check(bad(customPurpose({ features: { map: 'yes' } })).detail === 'features.map:not_bool', '功能值非布尔');
  check(bad(customPurpose({ settings: { e2ee: true } })).detail === 'settings.e2ee:unknown_key', 'settings 不能改 e2ee');
  check(bad(customPurpose({ description: 'x'.repeat(40 * 1024).slice(0, 200), icon: '📚', name: 'n', plugins: [{ manifest: goodManifest({ description: 'y'.repeat(500) }) }], features: {}, settings: {} })).ok, '正常大小通过');
  const huge = customPurpose({ plugins: Array.from({ length: 3 }, (_, i) => ({ id: `x.y${i}`, config: { s: 'z'.repeat(12000) } })) });
  check(bad(huge).detail === '$:too_large', '>32KB -> $:too_large', bad(huge).detail);
  check(bad(customPurpose({ id: 'Bad Id' })).detail === 'id:invalid', '坏 id');
  check(bad(customPurpose({ id: 'a'.repeat(33) })).detail === 'id:invalid', 'id 超长');
  check(bad(customPurpose({ name: '' })).detail === 'name:invalid', '空名字');
  check(bad(customPurpose({ v: 2 })).detail === 'v:unsupported', 'v≠1');
  const eleven = customPurpose({ features: {}, plugins: Array.from({ length: 11 }, (_, i) => ({ id: `x.y${i}` })) });
  check(bad(eleven).detail === 'plugins:max_10', '>10 个插件');
  check(bad(customPurpose({ features: { transcript: true }, settings: { transcript: false } })).detail === 'settings.transcript:conflict', 'transcript 冲突');
  check(/conflict_with_features\.focus/.test(bad(customPurpose({ features: { focus: false } })).detail), 'focus 与 lares.focus 项冲突', bad(customPurpose({ features: { focus: false } })));
  check(/need_exactly_one/.test(bad(customPurpose({ plugins: [{ id: 'lares.focus', manifestUrl: 'https://x/y' }] })).detail), '插件项两个来源');
  check(/duplicate/.test(bad(customPurpose({ plugins: [{ id: 'lares.focus' }, { id: 'lares.focus' }] })).detail), '同一插件两次');
  const bm = goodManifest({ bogus: 1 });
  const r = bad(customPurpose({ plugins: [{ id: 'lares.focus' }, { manifest: bm }] }));
  check(r.reason === 'bad_manifest' && r.detail === `plugins[1]:${validateManifest(bm).detail}`, '坏 manifest:reason/detail 与 validateManifest 一致', r);
  check(bad(customPurpose({ plugins: [{ id: 'lares.focus', config: { s: 'z'.repeat(5000) } }] })).detail === 'plugins[0].config:too_large', 'config > 4KB');

  console.log('\n[分享码]');
  const code = encodePurposeCode(customPurpose());
  check(code.startsWith('lares-purpose:') && !code.includes('=') && /^[A-Za-z0-9_-]+$/.test(code.slice(14)), '前缀 + base64url 无填充', code);
  const dec = decodePurposeCode(code);
  check(dec.ok && isDeepStrictEqual(dec.purpose, customPurpose()), '编码 → 解码 深相等', dec);
  check(!decodePurposeCode('lares-xx:' + code.slice(14)).ok, '前缀不对 -> 拒');
  check(!decodePurposeCode('lares-purpose:!!!').ok, '非 base64url -> 拒');
  check(!decodePurposeCode('lares-purpose:' + Buffer.from('not gzip').toString('base64url')).ok, '非 gzip -> 拒');
  const bomb = 'lares-purpose:' + gzipSync(Buffer.alloc(10 * 1024 * 1024, 0x20)).toString('base64url');
  const br = decodePurposeCode(bomb);
  check(!br.ok && br.detail === 'code:too_large', 'gzip 炸弹 -> too_large', br);
  const big = 'lares-purpose:' + gzipSync(Buffer.from(JSON.stringify({ x: 'a'.repeat(40 * 1024) }))).toString('base64url');
  check(decodePurposeCode(big).detail === 'code:too_large', '解压后 > 32KB -> too_large');
}

// 假 DashScope(cap_token)+ manifest 服务器
function startFake() {
  const server = http.createServer((req, res) => {
    if (req.url.startsWith('/api/v1/tokens')) {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ token: 'st-fake', expires_at: Math.floor(Date.now() / 1000) + 300 }));
    }
    if (req.url === '/good.json') {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify(goodManifest({ id: 'com.example.fetched', name: 'Fetched' })));
    }
    res.writeHead(404); res.end('nope');
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    port: server.address().port,
    close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); }),
  })));
}

async function main() {
  unitTests();
  const fake = await startFake();
  const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-features-'));
  const env = {
    LARES_PLUGIN_ALLOW_PRIVATE: '1',
    LARES_DASHSCOPE_API_KEY: 'sk-test-' + randomBytes(6).toString('hex'),
    LARES_DASHSCOPE_BASE: `http://127.0.0.1:${fake.port}`,
  };
  let srv = boot(PORT, dataDir, GLOBAL_PASS, env);
  const clients = [];
  const C = async (opts) => { const c = await connect(PORT, opts); clients.push(c); return c; };
  try {
    check(await waitHealth(PORT), '服务端启动');

    console.log('\n[默认值]');
    const { cid, verifier, ownerKey, owner } = await registerCircle(PORT, PASSCODE, 'u_owner');
    clients.push(owner);
    const f0 = owner.msg.circle?.features;
    check(f0 && ALL_KEYS.every((k) => typeof f0[k] === 'boolean') && Object.keys(f0).length === 9, 'welcome.circle.features 9 键全量', f0);
    check(f0?.map === false && f0.recording === false && f0.p2p === false && f0.devTools === false, '新圈 map/recording/p2p/devTools 关', f0);
    check(f0?.captions && f0.voiceNotes && f0.plugins && !f0.transcript && !f0.focus, '新圈 captions/voiceNotes/plugins 开,transcript/focus 关', f0);
    check(owner.msg.circle?.purpose === null, '新圈 purpose=null', owner.msg.circle?.purpose);
    const legacy = await C({ userId: 'u_legacy', auth: v1Auth(GLOBAL_PASS, 'home') });
    const lf = legacy.msg?.circle?.features;
    check(lf && ['captions', 'voiceNotes', 'map', 'recording', 'plugins', 'p2p', 'devTools'].every((k) => lf[k] === true), '老圈 / env 圈:存储型键全开', lf);
    const settingsDisk = () => JSON.parse(readFileSync(path.join(dataDir, 'circle_settings.json'), 'utf8'));
    // 新圈默认是不等待的落盘(fire-and-forget):轮询到文件出现再判
    const settingsFile = path.join(dataDir, 'circle_settings.json');
    for (let i = 0; i < 50 && !(existsSync(settingsFile) && settingsDisk()[cid]); i++) await new Promise((r) => setTimeout(r, 40));
    check(settingsDisk()[cid]?.features?.map === false, '新圈默认已落盘', settingsDisk()[cid]);

    console.log('\n[circle_features_set]');
    const alice = await C({ userId: 'u_a', name: 'Alice', auth: v2Auth(verifier, cid) });
    const bob = await C({ userId: 'u_b', name: 'Bob', auth: v2Auth(verifier, cid) });
    const fs = (features, who = owner, key = ownerKey) => who.req({ t: 'circle_features_set', circleId: cid, ownerKey: key, features }, ownerReply('circle_features_set'));
    let r = await fs({ map: true }, alice, 'nope');
    check(r?.reason === 'not_owner', '非圈主 -> not_owner', r);
    r = await fs({ teleport: true });
    check(r?.reason === 'bad_request', '未知键 -> bad_request', r);
    r = await fs({ map: 'yes' });
    check(r?.reason === 'bad_request', '非布尔 -> bad_request', r);
    r = await fs({});
    check(r?.reason === 'bad_request', '空 -> bad_request', r);
    alice.drain(() => true);
    r = await fs({ map: true, devTools: true });
    check(r?.t === 'owner_ok', '圈主改 -> owner_ok', r);
    let cs = await alice.waitFor((m) => m.t === 'circle_settings' && m.circle.id === cid && m.circle.features.map === true);
    check(cs?.circle.features.devTools === true && cs.circle.features.p2p === false, '成员收到 circle_settings,部分合并', cs?.circle.features);

    console.log('\n[transcript 双向同步]');
    r = await owner.req({ t: 'circle_transcript_set', circleId: cid, ownerKey, on: true }, ownerReply('circle_transcript_set'));
    cs = await alice.waitFor((m) => m.t === 'circle_settings' && m.circle.transcript === true);
    check(cs?.circle.features.transcript === true, 'circle_transcript_set on → features.transcript=true', cs?.circle);
    r = await fs({ transcript: false });
    cs = await alice.waitFor((m) => m.t === 'circle_settings' && m.circle.features.transcript === false);
    check(r?.t === 'owner_ok' && cs?.circle.transcript === false, 'features.transcript=false → circle.transcript=false', cs?.circle);

    console.log('\n[focus 键 ↔ lares.focus]');
    alice.drain(() => true);
    r = await fs({ focus: true });
    let pl = await alice.waitFor((m) => m.t === 'plugins' && m.circleId === cid);
    check(r?.t === 'owner_ok' && pl?.items.some((p) => p.id === 'lares.focus' && p.enabled), 'focus:true → 装上并启用 lares.focus', pl);
    cs = await alice.waitFor((m) => m.t === 'circle_settings' && m.circle.features.focus === true);
    check(Boolean(cs), 'circle_settings.features.focus=true');
    r = await fs({ focus: false });
    pl = await alice.waitFor((m) => m.t === 'plugins' && m.circleId === cid);
    check(pl?.items.some((p) => p.id === 'lares.focus' && p.enabled === false), 'focus:false → 停用但不卸载', pl);

    console.log('\n[闸门]');
    await join(owner, cid); await join(alice, cid); await join(bob, cid);
    // map 关
    await fs({ map: false });
    alice.drain(() => true); bob.drain(() => true);
    r = await alice.req({ t: 'loc', lat: 1, lng: 2 }, (m) => m.t === 'error' || m.t === 'member_loc');
    check(r?.t === 'error' && r.message === 'feature_off', 'map 关:loc → error feature_off', r);
    check(!(await bob.waitFor((m) => m.t === 'member_loc', 300)), 'map 关:别人收不到 member_loc');
    // p2p 关
    r = await alice.req({ t: 'p2p_signal', to: 'u_b', payload: 'x' }, (m) => m.t === 'error');
    check(r?.message === 'feature_off', 'p2p 关:p2p_signal → feature_off', r);
    check(!(await bob.waitFor((m) => m.t === 'p2p_signal', 300)), 'p2p 关:对方收不到');
    await fs({ p2p: true });
    bob.drain(() => true);
    alice.send({ t: 'p2p_signal', to: 'u_b', payload: 'x' });
    check(Boolean(await bob.waitFor((m) => m.t === 'p2p_signal')), 'p2p 开:正常转发');
    // recording 关
    r = await alice.req({ t: 'rec_start', circleId: cid }, (m) => m.t === 'rec_error' || m.t === 'member_rec');
    check(r?.t === 'rec_error' && r.reason === 'feature_off', 'recording 关:rec_start → rec_error feature_off', r);
    check(!(await bob.waitFor((m) => m.t === 'member_rec', 300)), 'recording 关:不回显');
    await fs({ recording: true });
    r = await alice.req({ t: 'rec_start', circleId: cid }, (m) => m.t === 'rec_error' || (m.t === 'member_rec' && m.userId === 'u_a'));
    check(r?.t === 'member_rec' && r.active === true, 'recording 开:回显 member_rec', r);
    alice.send({ t: 'rec_stop', circleId: cid });
    // captions
    const capReq = (c) => c.req({ t: 'cap_token' }, (m) => m.t === 'cap_token' || m.t === 'cap_error', 5000);
    r = await capReq(alice);
    check(r?.t === 'cap_token', 'captions 开:cap_token 签发', r);
    await fs({ captions: false });
    r = await capReq(alice);
    check(r?.t === 'cap_error' && r.reason === 'feature_off', 'captions 关:cap_error feature_off', r);
    // TestFlight 46 回归:实时字幕关、转写记录开 → 仍须签 token(否则谁的话都进不了记录),
    // 且本人追加的行本人实时收到、历史里也有
    r = await owner.req({ t: 'circle_transcript_set', circleId: cid, ownerKey, on: true }, ownerReply('circle_transcript_set'));
    check(r?.t === 'owner_ok', 'captions 关时开转写记录', r);
    r = await capReq(alice);
    check(r?.t === 'cap_token', 'captions 关 + transcript 开:cap_token 照样签发', r);
    alice.drain(() => true);
    r = await alice.req({ t: 'transcript_append', circleId: cid, id: 'own-1', text: '我自己说的话' }, (m) => m.t === 'transcript_appended' || m.t === 'transcript_error');
    check(r?.t === 'transcript_appended', 'captions 关 + transcript 开:transcript_append 成功', r);
    const ownLine = await alice.waitFor((m) => m.t === 'transcript_line' && m.item?.id === 'own-1');
    check(ownLine?.item?.userId === 'u_a', '发送者本人实时收到自己的 transcript_line', ownLine);
    r = await alice.req({ t: 'transcript_get', circleId: cid }, (m) => m.t === 'transcript_page' || m.t === 'transcript_error');
    check(r?.items?.some((it) => it.id === 'own-1' && it.userId === 'u_a'), '发送者本人的历史里有自己的话', r);
    r = await owner.req({ t: 'circle_transcript_set', circleId: cid, ownerKey, on: false }, ownerReply('circle_transcript_set'));
    r = await capReq(alice);
    check(r?.t === 'cap_error' && r.reason === 'feature_off', 'captions 关 + transcript 关:又回到 feature_off', r);
    // voiceNotes
    const postNote = () => fetch(`${BASE}/notes`, {
      method: 'POST', headers: { authorization: `Bearer ${verifier}`, 'content-type': 'application/json' },
      body: JSON.stringify({ circleId: cid, userId: 'u_a', audio: 'AAAA', durationSec: 1 }),
    });
    let hr = await postNote();
    check(hr.status === 201, 'voiceNotes 开:POST /notes 201', hr.status);
    await fs({ voiceNotes: false });
    hr = await postNote();
    const hb = await hr.json().catch(() => null);
    check(hr.status === 403 && hb?.error === 'feature_off', 'voiceNotes 关:POST /notes 403 feature_off', { s: hr.status, hb });
    // plugins 关
    await fs({ plugins: false });
    const instReply = (m) => (m.t === 'plugin_installed') || (m.t === 'owner_error' && m.op === 'plugin_install');
    r = await owner.req({ t: 'plugin_install', circleId: cid, ownerKey, manifest: goodManifest() }, instReply);
    check(r?.reason === 'feature_off', 'plugins 关:第三方 plugin_install → feature_off', r);
    r = await owner.req({ t: 'circle_purpose_apply', circleId: cid, ownerKey, purpose: { id: 'p1', name: 'P1', plugins: [{ manifest: goodManifest() }] } }, ownerReply('circle_purpose_apply'));
    check(r?.reason === 'feature_off' && /^plugins\[0\]/.test(r.detail ?? ''), 'plugins 关:用途装第三方 → feature_off', r);

    console.log('\n[用途:内置]');
    const apply = (purpose, who = owner, key = ownerKey) => {
      who.drain((m) => m.t === 'purpose_applied');
      return who.req({ t: 'circle_purpose_apply', circleId: cid, ownerKey: key, purpose }, ownerReply('circle_purpose_apply'), 8000);
    };
    r = await apply('study', alice, 'nope');
    check(r?.reason === 'not_owner', '非圈主 apply → not_owner', r);
    r = await apply('nope');
    check(r?.reason === 'bad_purpose', '未知内置用途 → bad_purpose', r);
    alice.drain(() => true);
    r = await apply('study');
    const pa = owner.inbox.find((m) => m.t === 'purpose_applied');
    check(r?.t === 'owner_ok' && pa?.purpose?.id === 'study' && pa.purpose.builtin === true && Array.isArray(pa.secrets), 'study → purpose_applied + owner_ok', { r, pa });
    check(!alice.inbox.some((m) => m.t === 'purpose_applied'), 'purpose_applied 只发给圈主');
    cs = await alice.waitFor((m) => m.t === 'circle_settings' && m.circle.purpose?.id === 'study');
    check(cs?.circle.features.focus === true && cs.circle.features.captions === false && cs.circle.features.voiceNotes === false, 'study:focus 开,captions/voiceNotes 关', cs?.circle.features);
    check(cs?.circle.plugins.some((p) => p.id === 'lares.focus' && p.enabled), 'study:lares.focus 已启用', cs?.circle.plugins);
    check(cs?.circle.features.map === false && cs.circle.features.recording === true, '内置用途不碰 map / recording', cs?.circle.features);
    const sum = await alice.waitFor((m) => m.t === 'circle_summary' && m.circleId === cid && m.purpose?.id === 'study');
    check(sum?.features?.focus === true, 'circle_summary 带 features + purpose', sum);
    r = await apply('meeting');
    cs = await alice.waitFor((m) => m.t === 'circle_settings' && m.circle.purpose?.id === 'meeting');
    check(cs?.circle.features.transcript === true && cs.circle.transcript === true && cs.circle.features.captions === true && cs.circle.features.focus === false && cs.circle.features.plugins === true,
      'meeting:transcript 开,captions 开,focus 关,plugins 开', cs?.circle);
    check(settingsDisk()[cid]?.purpose?.e2eeWarning === true, 'meeting:e2eeWarning 存进 purpose', settingsDisk()[cid]?.purpose);

    console.log('\n[用途:自定义 + 原子性]');
    // 先装一个第三方插件(带 manifestUrl 抓取)
    r = await apply({ id: 'mine', name: '我的', features: { map: true }, plugins: [{ manifestUrl: `http://127.0.0.1:${fake.port}/good.json`, enabled: true, config: { a: 1 } }] });
    check(r?.t === 'owner_ok', '自定义用途 + manifestUrl 安装', r);
    cs = await alice.waitFor((m) => m.t === 'circle_settings' && m.circle.purpose?.id === 'mine');
    check(cs?.circle.plugins.some((p) => p.id === 'com.example.fetched') && cs.circle.features.map === true && cs.circle.purpose.builtin === false, '装上 fetched + map 开', cs?.circle);

    const pluginsDisk = () => JSON.parse(readFileSync(path.join(dataDir, 'plugins.json'), 'utf8')).circles[cid];
    const before = { s: settingsDisk()[cid], p: pluginsDisk() };
    await owner.waitFor(() => false, 300);
    owner.drain(() => true);
    const beforeWire = await owner.req({ t: 'plugin_list', circleId: cid }, (m) => m.t === 'plugins');
    alice.drain(() => true);
    // 第 1 项合法新插件 + 改功能;第 2 项 manifestUrl 404
    r = await apply({
      id: 'broken', name: '坏的', features: { map: false, captions: false, devTools: false },
      settings: { knockRequired: true },
      plugins: [{ manifest: goodManifest({ id: 'com.example.ok' }) }, { manifestUrl: `http://127.0.0.1:${fake.port}/missing.json` }],
    });
    check(r?.reason === 'manifest_fetch_failed' && /^plugins\[1\]/.test(r.detail ?? ''), '第 2 项抓取失败 → manifest_fetch_failed plugins[1]', r);
    r = await apply({ id: 'broken2', name: '坏的', features: { map: false }, plugins: [{ manifest: goodManifest({ id: 'com.example.ok2' }) }, { manifest: goodManifest({ id: 'BAD' }) }] });
    check(r?.reason === 'bad_manifest' && /^plugins\[1\]/.test(r.detail ?? ''), '第 2 项坏 manifest → bad_manifest', r);
    owner.drain(() => true);
    const afterWire = await owner.req({ t: 'plugin_list', circleId: cid }, (m) => m.t === 'plugins');
    check(isDeepStrictEqual(beforeWire?.items, afterWire?.items), '失败后插件列表不变', { b: beforeWire?.items, a: afterWire?.items });
    check(isDeepStrictEqual(before.s, settingsDisk()[cid]) && isDeepStrictEqual(before.p, pluginsDisk()), '失败后磁盘上设置与插件不变');
    check(!(await alice.waitFor((m) => m.t === 'circle_settings' || m.t === 'plugins', 300)), '失败不广播');
    r = await apply({ id: 'x', name: 'X', plugins: Array.from({ length: 9 }, (_, i) => ({ manifest: goodManifest({ id: `com.example.m${i}` }) })) });
    check(r?.reason === 'too_many', '装完超过 10 个 → too_many', r);

    console.log('\n[导出]');
    r = await alice.req({ t: 'circle_purpose_export', circleId: cid, ownerKey: 'nope' }, ownerReply('circle_purpose_export'));
    check(r?.reason === 'not_owner', '非圈主导出 → not_owner', r);
    const ex = await owner.req({ t: 'circle_purpose_export', circleId: cid, ownerKey }, (m) => m.t === 'circle_purpose' || (m.t === 'owner_error' && m.op === 'circle_purpose_export'));
    const ep = ex?.purpose;
    check(ex?.t === 'circle_purpose' && ep?.id === 'mine' && Object.keys(ep.features).length === 9, '导出:id + 9 键', ex);
    check(ep?.plugins?.some((p) => p.id === 'lares.focus') && ep.plugins.some((p) => p.manifest?.id === 'com.example.fetched' && p.config?.a === 1), '导出:内置给 id,第三方给 manifest + config', ep?.plugins);
    check(!JSON.stringify(ep).includes('plg_') && !JSON.stringify(ep).includes('whsec_') && !JSON.stringify(ep).includes('state'), '导出不含 token / 密钥 / 共享状态');
    check(ep?.settings && ep.settings.e2eeWarning === false && typeof ep.settings.knockRequired === 'boolean', '导出 settings', ep?.settings);
    const vr = validatePurpose(ep);
    check(vr.ok, '导出的 JSON 通过 validatePurpose', vr);
    r = await apply(ep);
    check(r?.t === 'owner_ok', '导出的 JSON 能干净地重新应用', r);
    const dec = decodePurposeCode(encodePurposeCode(ep));
    check(dec.ok && isDeepStrictEqual(dec.purpose, ep), '导出 → 分享码 → 解码 一致');

    console.log('\n[bot API]');
    owner.send({ t: 'bot_token_create', circleId: cid, name: 'B', ownerKey });
    const tok = await owner.waitFor((m) => m.t === 'bot_token');
    hr = await fetch(`${BASE}/api/v1/circle`, { headers: { authorization: `Bearer ${tok?.token}` } });
    const bj = await hr.json().catch(() => null);
    check(hr.status === 200 && bj?.features && Object.keys(bj.features).length === 9 && bj.purpose?.id === 'mine', 'GET /api/v1/circle 带 features + purpose', bj);

    console.log('\n[重启持久化]');
    const featsBefore = (await owner.req({ t: 'circle_purpose_export', circleId: cid, ownerKey }, (m) => m.t === 'circle_purpose'))?.purpose;
    for (const c of clients) await c.close();
    clients.length = 0;
    await stop(srv);
    srv = boot(PORT, dataDir, GLOBAL_PASS, env);
    check(await waitHealth(PORT), '重启');
    const o2 = await C({ userId: 'u_owner', auth: v2Auth(verifier, cid, { ownerKey }) });
    check(o2.kind === 'welcome' && isDeepStrictEqual(o2.msg.circle?.features, featsBefore?.features) && o2.msg.circle?.purpose?.id === 'mine', '重启后 features + purpose 不变', { w: o2.msg?.circle, featsBefore });
    const leg2 = await C({ userId: 'u_legacy', auth: v1Auth(GLOBAL_PASS, 'home') });
    check(leg2.msg?.circle?.features?.map === true, '老圈重启后仍全开');
    check(existsSync(path.join(dataDir, 'circle_settings.json')), 'circle_settings.json 存在');
  } finally {
    for (const c of clients) await c.close?.().catch?.(() => {});
    await stop(srv);
    await fake.close();
  }
  console.log(T.fail === 0 ? `\n全部通过(${T.pass} 通过)` : `\n${T.pass} 通过,${T.fail} 失败`);
  if (T.fail && !process.env.DEBUG) console.log(srv.out.slice(-3000));
  process.exit(T.fail === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
