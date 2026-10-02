// 转写记录(明文归档 + E2EE 密文中继)端到端验证。契约:docs/plans/transcript-bot-contract.md §3/§4。
//
// 真实服务端进程 + 临时 DATA_DIR + 原始 WS 客户端;不 import 服务端代码。
// 用法:node test/transcript.mjs     (DEBUG=1 显示服务端 stderr)

import { createCipheriv, randomBytes } from 'node:crypto';
import { mkdtempSync, existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  wait, makeChecker, boot, waitHealth, stop, connect, join, registerCircle, v1Auth, v2Auth, ownerReply,
} from './lib/harness.mjs';

const PORT = 18980;
const GLOBAL_PASS = 'tr-global-' + randomBytes(4).toString('hex');
const PASSCODE = 'tr-pass-' + randomBytes(4).toString('hex');
const MARKER = 'PLAINTEXT_MARKER_' + randomBytes(4).toString('hex');
const T = makeChecker();
const { check } = T;

const isErr = (op) => (m) => m.t === 'transcript_error' && m.op === op;
const appendReply = (m) => m.t === 'transcript_appended' || (m.t === 'transcript_error' && m.op === 'append');

/// 所有数据文件内容拼起来(查明文泄露)
function allDataText(dir) {
  let out = '';
  for (const n of readdirSync(dir)) {
    const p = path.join(dir, n);
    if (statSync(p).isDirectory()) out += allDataText(p);
    else out += readFileSync(p, 'utf8');
  }
  return out;
}

/// 模拟客户端的 AES-GCM 加密(密钥随便取 —— 服务器根本不解,只看它不落明文)
function fakeBlob(text) {
  const key = randomBytes(32);
  const nonce = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', key, nonce);
  const ct = Buffer.concat([c.update(JSON.stringify({ text }), 'utf8'), c.final()]);
  return Buffer.concat([Buffer.from([1]), nonce, ct, c.getAuthTag()]).toString('base64');
}

async function main() {
  const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-tr-'));
  const env = { LARES_TRANSCRIPT_BURST: '8', LARES_TRANSCRIPT_RATE_PER_SEC: '2' };
  let child = boot(PORT, dataDir, GLOBAL_PASS, env);
  const open = [];
  const C = async (opts) => { const c = await connect(PORT, opts); open.push(c); return c; };
  try {
    if (!(await waitHealth(PORT))) throw new Error('服务端启动超时');

    // ── 注册圈 + 成员 ──
    const { cid, verifier, ownerKey, owner } = await registerCircle(PORT, PASSCODE);
    open.push(owner);
    const auth = (extra) => v2Auth(verifier, cid, extra);
    check(owner.msg?.circle?.transcript === false, 'welcome.circle.transcript 默认 false', owner.msg?.circle);

    console.log('\n[圈主闸门:circle_transcript_set]');
    const alice = await C({ userId: 'u_alice', name: 'Alice', auth: auth() });
    let r = await alice.req({ t: 'circle_transcript_set', circleId: cid, on: true, ownerKey: 'f'.repeat(64) }, ownerReply('circle_transcript_set'));
    check(r?.t === 'owner_error' && r.reason === 'not_owner', '钥匙不对 -> owner_error not_owner', r);
    r = await alice.req({ t: 'circle_transcript_set', circleId: cid, on: true }, ownerReply('circle_transcript_set'));
    check(r?.t === 'owner_error' && r.reason === 'not_owner', '不带钥匙 -> not_owner', r);
    r = await owner.req({ t: 'circle_transcript_set', circleId: cid, on: 'yes', ownerKey }, ownerReply('circle_transcript_set'));
    check(r?.t === 'owner_error' && r.reason === 'bad_request', 'on 非布尔 -> bad_request', r);
    const envCircle = 'trenv_' + randomBytes(3).toString('hex');
    const envUser = await C({ userId: 'u_env', auth: v1Auth(GLOBAL_PASS, envCircle) });
    r = await envUser.req({ t: 'circle_transcript_set', circleId: envCircle, on: true, ownerKey }, ownerReply('circle_transcript_set'));
    check(r?.t === 'owner_error' && r.reason === 'not_registered', '非注册圈 -> not_registered', r);

    // 先开房再开关,看 circle_summary / circle_settings 带字段
    await join(alice, cid);
    r = await alice.req({ t: 'transcript_append', circleId: cid, id: 'x0', text: 'hi' }, appendReply);
    check(r?.t === 'transcript_error' && r.reason === 'off', '转写未开 -> reason off', r);

    alice.drain(() => true);
    r = await owner.req({ t: 'circle_transcript_set', circleId: cid, on: true, ownerKey }, ownerReply('circle_transcript_set'));
    check(r?.t === 'owner_ok', '圈主开启 -> owner_ok', r);
    const settings = await alice.waitFor((m) => m.t === 'circle_settings' && m.circle?.id === cid);
    check(settings?.circle?.transcript === true, 'circle_settings 广播 transcript:true', settings);
    const summary = await alice.waitFor((m) => m.t === 'circle_summary' && m.circleId === cid && m.transcript === true);
    check(Boolean(summary), 'circle_summary 带 transcript:true', summary);

    console.log('\n[追加校验 + 署名]');
    const bob = await C({ userId: 'u_bob', name: 'Bob', auth: auth() });
    r = await bob.req({ t: 'transcript_append', circleId: cid, id: 'b1', text: 'x' }, appendReply);
    check(r?.reason === 'not_in_room', '不在房 -> not_in_room', r);
    await join(bob, cid);
    r = await bob.req({ t: 'transcript_append', circleId: cid, id: 'b1', text: '' }, appendReply);
    check(r?.reason === 'bad_text', '空文本 -> bad_text', r);
    r = await bob.req({ t: 'transcript_append', circleId: cid, id: 'b1', text: 'a'.repeat(2001) }, appendReply);
    check(r?.reason === 'bad_text', '2001 字 -> bad_text', r);
    r = await bob.req({ t: 'transcript_append', circleId: cid, id: 'x'.repeat(201), text: 'hi' }, appendReply);
    check(r?.reason === 'bad_id', 'id 超 200 -> bad_id', r);
    r = await bob.req({ t: 'transcript_append', circleId: cid, id: 42, text: 'hi' }, appendReply);
    check(r?.reason === 'bad_id', 'id 非字符串 -> bad_id', r);
    r = await bob.req({ t: 'transcript_append', circleId: 'c_other', id: 'b1', text: 'hi' }, appendReply);
    check(r?.reason === 'not_in_room', '别的圈 -> not_in_room', r);

    alice.drain(() => true);
    const t0 = Date.now();
    r = await bob.req({
      t: 'transcript_append', circleId: cid, id: 'b1', text: '你好 ' + MARKER, startedAt: t0 - 1500,
      name: 'Mallory', userId: 'u_mallory', ts: 1, seq: 999,
    }, appendReply);
    check(r?.t === 'transcript_appended' && r.id === 'b1' && r.seq === 1, '合法追加 -> transcript_appended seq=1', r);
    r = await bob.req({ t: 'transcript_append', circleId: cid, id: 'b1', text: '重发' }, appendReply);
    check(r?.t === 'transcript_appended' && r.seq === 1, '同 id 重发幂等,仍是 seq 1', r);
    const line = await alice.waitFor((m) => m.t === 'transcript_line');
    check(line?.item?.userId === 'u_bob' && line.item.name === 'Bob', 'transcript_line 署名取自会话(忽略 name/userId 字段)', line);
    check(line?.item?.seq === 1 && line.item.ts >= t0 && line.item.startedAt === t0 - 1500 && line.item.text.endsWith(MARKER), 'item 字段 seq/ts/startedAt/text', line);
    const dup = await alice.waitFor((m) => m.t === 'transcript_line', 300);
    check(dup === null, '幂等重发不重复广播', dup);

    // 改名后署名跟着会话走
    bob.send({ t: 'profile', name: 'Bobby' });
    await wait(50);
    for (let i = 2; i <= 7; i++) {
      r = await bob.req({ t: 'transcript_append', circleId: cid, id: 'b' + i, text: '第' + i + '句' }, appendReply);
    }
    check(r?.seq === 7, '连续追加 seq 到 7', r);

    console.log('\n[限速]');
    let limited = null;
    for (let i = 0; i < 12 && !limited; i++) {
      const x = await bob.req({ t: 'transcript_append', circleId: cid, id: 'rl' + i, text: 'spam' }, appendReply);
      if (x?.reason === 'rate_limited') limited = x;
    }
    check(Boolean(limited), '突发超出 -> rate_limited', limited);
    r = await alice.req({ t: 'transcript_append', circleId: cid, id: 'a1', text: 'alice 说话' }, appendReply);
    check(r?.t === 'transcript_appended', '限速按人计,别人不受影响', r);
    const lastSeq = r?.seq;

    console.log('\n[拉历史]');
    r = await alice.req({ t: 'transcript_get', circleId: cid, limit: 3 }, (m) => m.t === 'transcript_page' || isErr('get')(m));
    check(r?.t === 'transcript_page' && r.items.length === 3 && r.items[0].seq === lastSeq && r.items[0].seq > r.items[2].seq && r.more === true, '新→旧,limit 3,more:true', r);
    const p2 = await alice.req({ t: 'transcript_get', circleId: cid, before: 3, limit: 50 }, (m) => m.t === 'transcript_page');
    check(p2?.items.map((x) => x.seq).join(',') === '2,1' && p2.more === false, 'before=3 -> [2,1],more:false', p2?.items?.map((x) => x.seq));
    const named = (await alice.req({ t: 'transcript_get', circleId: cid, before: 3, limit: 1 }, (m) => m.t === 'transcript_page'))?.items?.[0];
    check(named?.name === 'Bobby', '改名后的追加用新名字', named);
    r = await alice.req({ t: 'transcript_get', circleId: cid, limit: 201 }, (m) => m.t === 'transcript_page' || isErr('get')(m));
    check(r?.t === 'transcript_error' && r.reason === 'bad_request', 'limit 201 -> bad_request', r);
    r = await alice.req({ t: 'transcript_get', circleId: cid }, (m) => m.t === 'transcript_page');
    check(r?.items.length === Math.min(50, lastSeq), '缺省 limit 50', r?.items?.length);
    // 非成员:证明的是别的圈
    r = await envUser.req({ t: 'transcript_get', circleId: cid }, (m) => m.t === 'transcript_page' || isErr('get')(m));
    check(r?.t === 'transcript_error' && r.reason === 'auth_scope', '别圈的连接拉历史 -> auth_scope', r);
    // 本圈成员不在房也能拉(圈子授权即可)
    const lobbyOnly = await C({ userId: 'u_lobby', auth: auth() });
    r = await lobbyOnly.req({ t: 'transcript_get', circleId: cid, limit: 1 }, (m) => m.t === 'transcript_page' || isErr('get')(m));
    check(r?.t === 'transcript_page' && r.items.length === 1, '本圈已认证、未进房也可拉历史', r);

    const file = path.join(dataDir, 'transcripts', encodeURIComponent(cid) + '.jsonl');
    const lines = readFileSync(file, 'utf8').trim().split('\n');
    check(lines.length === lastSeq && JSON.parse(lines[0]).userId === 'u_bob', `JSONL 落盘 ${lastSeq} 行`, lines.length);

    console.log('\n[重启后 seq 延续]');
    for (const c of open.splice(0)) await c.close();
    await stop(child);
    child = boot(PORT, dataDir, GLOBAL_PASS, env);
    if (!(await waitHealth(PORT))) throw new Error('重启超时');
    const alice2 = await C({ userId: 'u_alice', name: 'Alice', auth: auth() });
    check(alice2.msg?.circle?.transcript === true, '重启后设置仍在 transcript:true', alice2.msg?.circle);
    await join(alice2, cid);
    r = await alice2.req({ t: 'transcript_append', circleId: cid, id: 'after', text: 'after restart' }, appendReply);
    check(r?.seq === lastSeq + 1, `重启后 seq = ${lastSeq + 1}`, r);
    r = await alice2.req({ t: 'transcript_get', circleId: cid, limit: 200 }, (m) => m.t === 'transcript_page');
    check(r?.items.length === lastSeq + 1, '重启后历史完整', r?.items?.length);

    console.log('\n[清空]');
    const owner2 = await C({ userId: 'u_owner', auth: auth() });
    r = await alice2.req({ t: 'transcript_clear', circleId: cid, ownerKey: 'nope' }, ownerReply('transcript_clear'));
    check(r?.t === 'owner_error' && r.reason === 'not_owner', '非圈主清空 -> not_owner', r);
    alice2.drain(() => true);
    r = await owner2.req({ t: 'transcript_clear', circleId: cid, ownerKey }, ownerReply('transcript_clear'));
    check(r?.t === 'owner_ok', '圈主清空 -> owner_ok', r);
    const cleared = await alice2.waitFor((m) => m.t === 'transcript_cleared' && m.circleId === cid);
    check(Boolean(cleared), '在房成员收到 transcript_cleared', cleared);
    const clearedOwner = await owner2.waitFor((m) => m.t === 'transcript_cleared');
    check(Boolean(clearedOwner), '圈主(在大厅)也收到 transcript_cleared', clearedOwner);
    check(!existsSync(file), '归档文件已删除', file);
    r = await alice2.req({ t: 'transcript_get', circleId: cid }, (m) => m.t === 'transcript_page');
    check(r?.items.length === 0 && r.more === false, '清空后历史为空', r);
    r = await alice2.req({ t: 'transcript_append', circleId: cid, id: 'post', text: 'post clear' }, appendReply);
    check(r?.seq === lastSeq + 2, '清空后 seq 不回退', r);

    console.log('\n[E2EE:append 拒绝 + 密文中继]');
    r = await owner2.req({ t: 'circle_e2ee_set', circleId: cid, enabled: true, ownerKey }, ownerReply('circle_e2ee_set'));
    check(r?.t === 'owner_ok', '开启 E2EE', r);
    r = await alice2.req({ t: 'transcript_append', circleId: cid, id: 'e1', text: 'secret ' + MARKER }, appendReply);
    check(r?.reason === 'e2ee', 'E2EE 圈 append -> reason e2ee', r);
    r = await alice2.req({ t: 'transcript_get', circleId: cid }, (m) => m.t === 'transcript_page' || isErr('get')(m));
    check(r?.t === 'transcript_error' && r.reason === 'e2ee', 'E2EE 圈 transcript_get -> e2ee', r);

    // 成员名单:alice、bob(第一阶段进过房)、carol 现在进一次再走
    const carol = await C({ userId: 'u_carol', auth: auth() });
    await join(carol, cid);
    await carol.close();
    // bob 两台设备在线:一台在房,一台在大厅;alice 两台设备都在房(发送端 + 另一台)
    const bobRoom = await C({ userId: 'u_bob', deviceId: 'bob-1', auth: auth() });
    await join(bobRoom, cid);
    const aliceDev2 = await C({ userId: 'u_alice', deviceId: 'alice-2', auth: auth() });
    await join(aliceDev2, cid);
    for (const c of [alice2, bobRoom, aliceDev2]) c.drain((m) => m.t === 'transcript_relay');

    const relayReply = (m) => m.t === 'transcript_relayed' || isErr('relay')(m);
    r = await alice2.req({ t: 'transcript_relay', circleId: cid, blob: 'not base64!!' }, relayReply);
    check(r?.reason === 'bad_blob', '非 base64 -> bad_blob', r);
    r = await alice2.req({ t: 'transcript_relay', circleId: cid, blob: 'A'.repeat(8196) }, relayReply);
    check(r?.reason === 'bad_blob', '超 8192 -> bad_blob', r);
    const notInRoom = await C({ userId: 'u_lobby2', auth: auth() });
    r = await notInRoom.req({ t: 'transcript_relay', circleId: cid, blob: fakeBlob('x') }, relayReply);
    check(r?.reason === 'not_in_room', '不在房中继 -> not_in_room', r);

    const blobs = [fakeBlob('第一句 ' + MARKER), fakeBlob('第二句 ' + MARKER)];
    const rids = [];
    for (const b of blobs) {
      r = await alice2.req({ t: 'transcript_relay', circleId: cid, blob: b }, relayReply);
      rids.push(r?.rid);
    }
    check(rids.every((x) => typeof x === 'string' && x.length > 0), 'transcript_relayed 回 rid', rids);
    const gotBob = await bobRoom.waitFor((m) => m.t === 'transcript_relay' && m.items?.[0]?.rid === rids[1]);
    check(gotBob?.items?.[0]?.blob === blobs[1] && typeof gotBob.items[0].ts === 'number', '在线成员实时收到 {rid,blob,ts}', gotBob);
    const gotAlice2 = await aliceDev2.waitFor((m) => m.t === 'transcript_relay' && m.items?.[0]?.rid === rids[0]);
    check(Boolean(gotAlice2), '发送者的另一台设备也收到', gotAlice2);
    const echo = await alice2.waitFor((m) => m.t === 'transcript_relay', 300);
    check(echo === null, '发送这台设备不回显', echo);

    const relayFile = path.join(dataDir, 'transcript_relay', encodeURIComponent(cid) + '.json');
    await wait(150);
    let q = JSON.parse(readFileSync(relayFile, 'utf8'));
    check(q.members.includes('u_carol') && q.members.includes('u_bob') && q.members.includes('u_alice'), '持久化成员名单含进过房的人', q.members);
    check(q.queues.u_carol?.length === 2 && q.queues.u_bob?.length === 2, '离线 carol 与在线 bob 都入队(未 ack 前保留)', Object.fromEntries(Object.entries(q.queues).map(([k, v]) => [k, v.length])));
    check(!q.queues.u_alice, '发送者本人不入队', Object.keys(q.queues));

    console.log('\n[离线补推 + ack]');
    const carol2 = await C({ userId: 'u_carol', auth: auth() });
    const pend = await carol2.waitFor((m) => m.t === 'transcript_relay' && m.circleId === cid);
    check(pend?.items?.length === 2 && pend.items.map((x) => x.rid).join() === rids.join(), 'hello 后补推 2 条积压', pend);
    await join(carol2, cid);
    const dupPush = await carol2.waitFor((m) => m.t === 'transcript_relay', 300);
    check(dupPush === null, 'hello 已推过,join 不重复推', dupPush);
    carol2.send({ t: 'transcript_relay_ack', circleId: cid, rids: [rids[0]] });
    await wait(200);
    q = JSON.parse(readFileSync(relayFile, 'utf8'));
    check(q.queues.u_carol?.length === 1 && q.queues.u_carol[0].rid === rids[1], 'ack 一条 -> 盘上只剩另一条', q.queues.u_carol);
    await carol2.close();
    const carol3 = await C({ userId: 'u_carol', auth: auth() });
    const pend3 = await carol3.waitFor((m) => m.t === 'transcript_relay');
    check(pend3?.items?.length === 1 && pend3.items[0].rid === rids[1], '重连只补推未 ack 的那条', pend3);
    carol3.send({ t: 'transcript_relay_ack', circleId: cid, rids: [rids[1], 'bogus'] });
    await wait(200);
    await carol3.close();
    const carol4 = await C({ userId: 'u_carol', auth: auth() });
    const pend4 = await carol4.waitFor((m) => m.t === 'transcript_relay', 500);
    check(pend4 === null, '全部 ack 后重连不再补推', pend4);
    q = JSON.parse(readFileSync(relayFile, 'utf8'));
    check(!q.queues.u_carol, '盘上 carol 队列已清', q.queues.u_carol);

    // 新人:从没进过房 -> 不在名单,没有积压;进房后才收后续
    const dave = await C({ userId: 'u_dave', auth: auth() });
    const davePend = await dave.waitFor((m) => m.t === 'transcript_relay', 400);
    check(davePend === null, '从没进过房的人没有积压', davePend);

    check(!readFileSync(relayFile, 'utf8').includes(MARKER) && readFileSync(relayFile, 'utf8').includes(blobs[0]), '中继文件只有 blob,不含明文标记', null);
    // 明文归档阶段的 MARKER 已被清空删除;E2EE 阶段的 append 被拒;所以整个数据目录都不该有
    check(!allDataText(dataDir).includes(MARKER), '整个 DATA_DIR 不含明文标记', null);

    console.log('\n[关转写 -> relay off;清空含队列]');
    r = await bobRoom.req({ t: 'transcript_relay', circleId: cid, blob: fakeBlob('q') }, relayReply);
    check(r?.t === 'transcript_relayed', '再中继一条(给清空用)', r);
    await wait(100);
    r = await owner2.req({ t: 'transcript_clear', circleId: cid, ownerKey }, ownerReply('transcript_clear'));
    check(r?.t === 'owner_ok', 'E2EE 圈清空 -> owner_ok', r);
    await wait(150);
    q = JSON.parse(readFileSync(relayFile, 'utf8'));
    check(Object.keys(q.queues).length === 0, '清空后离线队列全空', q.queues);
    r = await owner2.req({ t: 'circle_transcript_set', circleId: cid, on: false, ownerKey }, ownerReply('circle_transcript_set'));
    r = await bobRoom.req({ t: 'transcript_relay', circleId: cid, blob: fakeBlob('q') }, relayReply);
    check(r?.reason === 'off', '转写关闭后 relay -> off', r);
    await owner2.req({ t: 'circle_e2ee_set', circleId: cid, enabled: false, ownerKey }, ownerReply('circle_e2ee_set'));
    await owner2.req({ t: 'circle_transcript_set', circleId: cid, on: true, ownerKey }, ownerReply('circle_transcript_set'));
    r = await bobRoom.req({ t: 'transcript_relay', circleId: cid, blob: fakeBlob('q') }, relayReply);
    check(r?.reason === 'not_e2ee', '非 E2EE 圈 relay -> not_e2ee', r);

    console.log('\n[解散圈子清干净]');
    r = await bobRoom.req({ t: 'transcript_append', circleId: cid, id: 'final', text: 'bye' }, appendReply);
    check(r?.t === 'transcript_appended', '解散前再写一条', r);
    owner2.send({ t: 'bot_token_create', circleId: cid, name: 'Bot', ownerKey });
    const tok = await owner2.waitFor((m) => m.t === 'bot_token');
    check(Boolean(tok?.token), '解散前建一个机器人 token', tok);
    r = await owner2.req({ t: 'circle_delete', circleId: cid, ownerKey }, ownerReply('circle_delete'));
    check(r?.t === 'owner_ok', 'circle_delete -> owner_ok', r);
    await wait(300);
    check(!existsSync(file), '归档文件已删', file);
    check(!existsSync(relayFile), '中继队列文件已删', relayFile);
    const seqFile = path.join(dataDir, 'transcripts', '_seq.json');
    check(!existsSync(seqFile) || !(cid in JSON.parse(readFileSync(seqFile, 'utf8'))), 'seq 下限记录已删', null);
    const botFile = path.join(dataDir, 'bot_tokens.json');
    check(!readFileSync(botFile, 'utf8').includes(cid), '机器人 token 已删', null);
    const api = await fetch(`http://127.0.0.1:${PORT}/api/v1/circle`, { headers: { authorization: `Bearer ${tok.token}` } });
    check(api.status === 401, '解散后该 token 调 API -> 401', api.status);
  } finally {
    for (const c of open) await c.close();
    await stop(child);
    if (process.env.DEBUG) console.log(child.out);
  }
  console.log(`\n${T.fail === 0 ? '全部通过' : `${T.fail} 项失败`}(${T.pass} 通过)`);
  process.exit(T.fail === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('✗ 测试异常:', e);
  process.exit(1);
});
