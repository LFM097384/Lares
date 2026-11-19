// ember-meet · Ember 平台 port(../ember/PORT.md)的「模拟真人网页客户端」实现。
//
// 下面接一个 driver(driver.mjs:Chromium 里的会议网页 + 平台 adapter;测试里换成假 driver),上面交给 createEmber。
// driver 形状:
//   join() / leave()               进会(含大厅等待)/ 离会(幂等)
//   sendChat(text)                 往会议聊天发一条(公开;访客没有私信)
//   on(ev, fn) 事件:
//     'caption'      (speaker, text)  一句**定稿**字幕(driver 已去重;speaker = 平台字幕上的显示名)
//     'chat'         (author, text)   一条别人发的新聊天
//     'roster'       (names[])        参会者面板里看到的名字(面板开着时才有)
//     'state'        (state)          joining / lobby / in-meeting / captions-on / captions-unavailable …(只有状态,无内容)
//     'disconnected' (reason)
//
// 身份:网页访客拿不到平台的用户 id,只有显示名。Ember id = `mt_` + sha256(规范化显示名) 前 12 位。
//   ⇒ 同名的人会被当成一个人;显示名不是认证(README「信任模型」)。
// 文字来源 = 平台实时字幕(port.transcripts = true → 'transcript'(id, text)),Ember 只收已在聊天里「@炉灵 同意」的人。
// 房间通道 = 会议聊天。命令解析复用 ember-jitsi/commands.mjs(同一套中文命令)。
// **访客没有私信**,而且 Teams 会议聊天会留在会后的聊天记录里,所以:
//   · 炉灵写的一切都是全员可见的;公告里明说。
//   · 回答、记忆列表照常公开(都来自会上所有人听到的内容 / 已放行的记忆)。
//   · 纪要草稿公开,但 roleRisk(可能暴露身份)条目**不显示内容**,只给编号;只能「泛化」或「删除」,不能「保留」
//     (没人能在聊天里看到原文就不该让它原样放行)。
import { createHash, randomUUID, generateKeyPairSync, sign as edSign } from 'node:crypto';
import { canonicalJSON } from '../ember/core/crypto.mjs';
// 命令解析与帮助文字来自 ember-jitsi(同一仓库,同一套聊天命令);这里只换掉私信相关的说法。
import { parseCommand, BOT_NAME } from '../ember-jitsi/commands.mjs';
import { normalizeName } from './captions.mjs';

export const SELF_ID = 'ember-meet-bot';
const KIND_ZH = { decision: '决定', todo: '待办', idea: '观点', fact: '公共事实' };
const ERR_ZH = {
  not_acked: '请先在聊天里发「@炉灵 同意」', not_convener: '只有召集人能散会', unknown_draft: '没有这个草稿',
  hash_mismatch: '草稿已经变了,请按最新草稿重新批准', bad_sig: '签名无效', replay: '重复的批准', key_mismatch: '你已同意过',
  already_released: '草稿已放行', not_allowed: '只有当时批准这条的人能撤回', empty: '目前没有可写进纪要的内容', unknown_item: '没有这个条目',
  bad_request: '请求不完整', unknown_skill: '不支持', internal: '内部错误', bad_key: '公钥无效', bad_action: '不支持的操作',
};

export const meetUserId = (name) => `mt_${createHash('sha256').update(normalizeName(name).toLowerCase()).digest('hex').slice(0, 12)}`;

export function announceText(platformLabel = '会议') {
  return [
    `大家好,我是${BOT_NAME}(Ember),一个 AI 会议助手,以访客身份在这场${platformLabel}里,参会者列表里能看到「${BOT_NAME}」。`,
    '规则(受查塔姆规则启发,非官方):会上说的内容可以带出去,但不说是谁说的。',
    `· 我读的是本会议的实时字幕。只有在聊天里发「@${BOT_NAME} 同意」的人,其字幕才进入我的账本;没同意的人的字幕直接丢弃。`,
    '· 我不录音;原话只在内存里改写成不带名字的账本,散会即清空。',
    `· 注意:我是访客,发不了私信。我在这里写的一切(回答、草稿、纪要)所有人都看得见,并且会留在会议聊天记录里。草稿里可能暴露身份的条目我不显示内容。`,
    '· 纪要要 k 个不同的参会者批准才放行,且不带名字和单位。显示名不是身份认证,批准按「不同的显示名」计数。',
    `命令:@${BOT_NAME} 帮助`,
  ].join('\n');
}

export const HELP = [
  `【${BOT_NAME} 命令】都在会议聊天里发,先 @${BOT_NAME}`,
  `@${BOT_NAME} 同意 —— 同意规则(之后你的字幕才进入账本)`,
  `@${BOT_NAME} 问 <问题> —— 问刚才讨论的内容(答案公开在聊天里)`,
  `@${BOT_NAME} 纪要 —— 生成纪要草稿(公开在聊天里;可能暴露身份的条目不显示内容)`,
  `@${BOT_NAME} 批准 D1 —— 批准草稿;够 k 人才放行`,
  `@${BOT_NAME} 泛化|删除 D1 <序号> —— 处理标 ⚠ 的条目(会清空已有批准)`,
  `@${BOT_NAME} 记忆 / 撤回 M1 —— 查看 / 撤回已放行的记忆(只有当时的批准人能撤回)`,
  `@${BOT_NAME} 结束 —— 散会(只有召集人)`,
].join('\n');

const b64 = (buf) => Buffer.from(buf).toString('base64');

/**
 * @param {object} driver   见文件头
 * @param {object} [o]
 * @param {string} [o.platformLabel]   公告里的平台名(「Teams 会议」)
 * @param {string|null} [o.convenerName]  召集人显示名(排到名单最前 → 成为 Ember 的 convener)
 * @param {(ev:object)=>void} [o.onHost]  notifyHost 的宿主回调(只有元数据)
 * @param {(ev:object)=>void} [o.meter]   元数据计量(字幕条数 / 长度;绝无文字)
 */
export function meetPort(driver, { selfId = SELF_ID, selfName = BOT_NAME, platformLabel = '会议', log = () => {}, onHost = () => {}, meter = () => {}, announce = true, convenerName = null } = {}) {
  const handlers = new Map();
  const emit = (ev, ...args) => { for (const fn of handlers.get(ev) ?? []) { try { fn(...args); } catch (e) { log(`port handler ${ev}: ${e.message}`); } } };
  const present = new Map(); // id → {name}
  const keys = new Map(); // id → {privateKey, pubB64}(托管)
  const selfKey = normalizeName(selfName).toLowerCase();
  const convKey = convenerName ? normalizeName(convenerName).toLowerCase() : null;
  let st = { sid: null, k: null, acked: new Set(), convenerId: null };
  let lastAckedCount = -1;
  const drafts = new Map(); // 'D1' → {draftId, draftHash, items:[{id, hidden}]}
  const draftShort = new Map();
  const mem = new Map();
  const memShort = new Map();
  let joined = false;
  let left = false;
  let lastAnswer = null;

  const pub = (text) => Promise.resolve(driver.sendChat(text)).catch((e) => log(`聊天发送失败: ${e.message}`));
  const isSelfName = (name) => normalizeName(name).toLowerCase() === selfKey;

  /// 显示名 → Ember id;第一次见到就发 'joined'
  function seen(rawName) {
    const name = normalizeName(rawName);
    if (!name || isSelfName(name)) return null;
    const id = meetUserId(name);
    if (!present.has(id)) { present.set(id, { name }); emit('joined', id, name); }
    return id;
  }

  function shortDraft(draftId) {
    if (!draftShort.has(draftId)) draftShort.set(draftId, `D${draftShort.size + 1}`);
    return draftShort.get(draftId);
  }
  function shortMem(itemId) {
    if (!memShort.has(itemId)) { const s = `M${memShort.size + 1}`; memShort.set(itemId, s); mem.set(s, itemId); }
    return memShort.get(itemId);
  }
  const latestDraft = () => [...drafts.keys()].pop() ?? null;

  function onChat(author, text) {
    if (left) return;
    const id = seen(author);
    if (!id) return;
    const c = parseCommand(text, { direct: false });
    if (!c) return;
    const name = present.get(id)?.name ?? '';
    const say = (m) => pub(`${BOT_NAME} → ${name}:${m}`);
    const toEmber = (msg) => emit('message', id, msg);
    switch (c.cmd) {
      case 'help': return pub(HELP);
      case 'bad_envelope': case 'envelope': return say('这个平台上不支持 EMBER1 信封(访客没有私信)');
      case 'ack': {
        if (!keys.has(id)) {
          const { privateKey, publicKey } = generateKeyPairSync('ed25519');
          const raw = Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url');
          keys.set(id, { privateKey, pubB64: b64(raw) });
        }
        return toEmber({ t: 'ack', pubKey: keys.get(id).pubB64 });
      }
      case 'ask': return toEmber({ t: 'ask', q: c.q });
      case 'minutes': return toEmber({ t: 'skill', name: 'minutes', args: {} });
      case 'approve': {
        const s = c.draft ?? latestDraft();
        const d = s ? drafts.get(s) : null;
        if (!d) return say('没有待批准的草稿');
        if (!keys.has(id)) return say(ERR_ZH.not_acked);
        const nonce = randomUUID();
        const sig = edSign(null, Buffer.from(canonicalJSON({ sid: st.sid, draftId: d.draftId, draftHash: d.draftHash, nonce }), 'utf8'), keys.get(id).privateKey).toString('base64');
        return toEmber({ t: 'approve', draftId: d.draftId, draftHash: d.draftHash, nonce, sig });
      }
      case 'review': {
        const s = c.draft ?? latestDraft();
        const d = s ? drafts.get(s) : null;
        const it = d?.items[c.item - 1];
        if (!it) return say(ERR_ZH.unknown_item);
        if (c.action === 'keep' && it.hidden) return say(`第 ${c.item} 条内容没在聊天里显示,不能原样保留;请用「泛化」或「删除」`);
        return toEmber({ t: 'review', draftId: d.draftId, itemId: it.id, action: c.action });
      }
      case 'mem_list': return toEmber({ t: 'mem_list' });
      case 'mem_retract': {
        const itemId = mem.get(c.item);
        if (!itemId) return say('没有这条记忆(先发「@炉灵 记忆」看编号)');
        return toEmber({ t: 'mem_retract', itemId });
      }
      case 'end': return toEmber({ t: 'end' });
      default: return undefined;
    }
  }

  function renderDraft(s, d) {
    const lines = [`【${BOT_NAME}·纪要草稿 ${s}】全员可见;需 ${d.k} 位不同的参会者批准才放行。`];
    d.items.forEach((it, i) => {
      if (it.roleRisk) lines.push(`${i + 1}. [${KIND_ZH[it.kind] ?? it.kind}] ⚠ 可能暴露身份,内容不在聊天中显示;不处理则不放行(@${BOT_NAME} 泛化|删除 ${s} ${i + 1})`);
      else lines.push(`${i + 1}. [${KIND_ZH[it.kind] ?? it.kind}] ${it.topic}:${it.text}`);
    });
    lines.push(`批准:@${BOT_NAME} 批准 ${s}(内容一变,已有批准作废)`);
    return lines.join('\n');
  }

  const port = {
    selfId,
    get transcripts() { return true; },
    isHuman: (id) => typeof id === 'string' && id.startsWith('mt_') && present.has(id),
    nameOf: (id) => present.get(id)?.name ?? '',
    on(ev, fn) { if (!handlers.has(ev)) handlers.set(ev, []); handlers.get(ev).push(fn); return port; },
    participants: () => {
      const xs = [...present].map(([id, p]) => ({ id, name: p.name }));
      if (convKey) xs.sort((a, b) => Number(b.name.toLowerCase() === convKey) - Number(a.name.toLowerCase() === convKey));
      return xs;
    },
    async join() {
      if (joined) return;
      joined = true;
      await driver.join();
      if (convenerName) seen(convenerName); // 召集人先入名单(Ember 把第一个进来的人当召集人)
      if (announce) await pub(announceText(platformLabel));
    },
    async leave() {
      if (left) return;
      left = true;
      for (const k of keys.values()) k.privateKey = null;
      keys.clear();
      try { await driver.leave(); } catch (e) { log(`离会失败: ${e.message}`); }
    },
    notifyHost(ev) { try { onHost(ev?.type === 'released' ? { type: 'released', items: (ev.itemIds ?? []).length } : { type: ev?.type, on: ev?.on }); } catch { /* */ } },
    async send(obj, toId = null) {
      if (!obj || typeof obj.t !== 'string' || left) return;
      switch (obj.t) {
        case 'state': {
          st = { sid: obj.sid, k: obj.k, acked: new Set((obj.members ?? []).filter((m) => m.acked).map((m) => m.id)), convenerId: obj.convenerId };
          const n = st.acked.size;
          if (n !== lastAckedCount && joined) { lastAckedCount = n; await pub(`${BOT_NAME}:已同意 ${n} 人 · 纪要放行需 ${obj.k} 人批准`); }
          return;
        }
        case 'answer': {
          // 聊天是公开的:同一回答只发一次,也不写是谁问的
          const key = `${obj.q}\u0000${obj.a}`;
          if (key === lastAnswer) return undefined;
          lastAnswer = key;
          return void await pub(`【${BOT_NAME}·回答】\n问:${obj.q}\n答:${obj.a}`);
        }
        case 'draft': {
          const d = obj.draft;
          const s = shortDraft(d.draftId);
          drafts.set(s, { draftId: d.draftId, draftHash: d.draftHash, items: d.items.map((i) => ({ id: i.id, hidden: Boolean(i.roleRisk) })), k: d.k });
          return void await pub(renderDraft(s, d));
        }
        case 'approvals': {
          const s = shortDraft(obj.draftId);
          if (obj.count > 0) return void await pub(`${BOT_NAME}:纪要草稿 ${s} 已获 ${obj.count}/${obj.k} 人批准${obj.count < obj.k ? ',未放行' : ''}`);
          return undefined;
        }
        case 'released': return void await pub(`【${BOT_NAME}·已放行纪要 ${shortDraft(obj.draftId)}】\n${obj.text}`);
        case 'mem': {
          const lines = [`【${BOT_NAME}·本圈记忆】`, ...(obj.items ?? []).map((i) => `${shortMem(i.id)}. [${KIND_ZH[i.kind] ?? i.kind}] ${i.text}`)];
          if (!(obj.items ?? []).length) lines.push('(空)');
          lines.push(`撤回:@${BOT_NAME} 撤回 M编号(只有当时批准的人能撤回)`);
          return void await pub(lines.join('\n'));
        }
        case 'mem_retracted': return void await pub(`${BOT_NAME}:记忆 ${memShort.get(obj.itemId) ?? '?'} 已撤回,并从所有派生文件中重建删除`);
        case 'error': {
          if (!toId) return undefined;
          return void await pub(`${BOT_NAME} → ${present.get(toId)?.name ?? ''}:操作 ${obj.op} 未完成 —— ${ERR_ZH[obj.code] ?? obj.code}`);
        }
        case 'ended': {
          const r = obj.receipt ?? {};
          return void await pub(`【${BOT_NAME}】散会。放行 ${r.counts?.releases ?? 0} 份纪要;会中账本已清空。回执 sha256=${String(r.sha256 ?? '').slice(0, 16)}…  ${BOT_NAME}离开会议。`);
        }
        default: return undefined;
      }
    },
  };

  driver.on('caption', (speaker, text) => {
    if (left) return;
    const id = seen(speaker);
    if (!id) return;
    const t = String(text ?? '');
    meter({ ev: 'caption_final', speaker: id, chars: t.length, acked: st.acked.has(id) });
    emit('transcript', id, t);
  });
  driver.on('chat', (author, text) => { void onChat(author, text); });
  driver.on('roster', (names) => { for (const n of names ?? []) seen(n); });
  driver.on('disconnected', (why) => emit('disconnected', why));

  port._debug = () => ({ present: present.size, custodial: keys.size, drafts: [...drafts.keys()], mem: [...mem.keys()] });
  return port;
}
