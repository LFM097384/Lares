// ember-jitsi · Ember 平台 port(../ember/PORT.md)的 Jitsi 实现。
//
// 下面接一个「bridge」(bridge.mjs:无头 Chromium + lib-jitsi-meet;测试里换成假 bridge),上面交给 createEmber。
// bridge 形状:
//   join() / leave()                       进会 / 离会(leave 幂等)
//   sendPublic(text) / sendPrivate(id, text)   会议聊天 / 私信
//   on(ev, fn)  事件:
//     'participant' (id, name, hidden)     有人在场(入会或进会时已在场);hidden = Jitsi 隐藏参与者(录制器等)
//     'name'        (id, name)             改显示名
//     'left'        (id)
//     'audio'       (id, Int16Array pcm, sampleRate)   逐人分轨,单声道
//     'chat'        (id, text, isPrivate)  公开聊天或发给炉灵的私信
//     'disconnected'(reason)
//
// 房间通道 = Jitsi 会议聊天。人用文字命令(commands.mjs),port 把它翻成 Ember 协议消息;
// Ember 发出的协议消息(state / answer / draft / approvals / released / mem / ended / error)
// 再翻成聊天文字。**公开聊天只出现:规则公告、计数、已放行的纪要、散会回执。** 答案、草稿、记忆列表只私信给已同意的人。
//
// 签名(k-of-n):
//   · 托管模式(缺省,给只用 Jitsi 网页的人):「@炉灵 同意」时 port 为该 endpoint 生成 Ed25519 密钥对(只在内存),
//     「批准 D1」时代签。签名只证明「这个 Jitsi endpoint 在聊天里说了批准」,真正的保证是 k 个不同的 endpoint。
//   · 自持密钥模式:客户端私信 `EMBER1 {"t":"ack","pubKey":…}` / `EMBER1 {"t":"approve",…}`,私钥不离开它的浏览器;
//     port 原样转发,并把原始协议消息也以 EMBER1 信封私信给它(它要 sid / draftHash 才能签)。
import { randomUUID, generateKeyPairSync, sign as edSign } from 'node:crypto';
import { canonicalJSON } from '../ember/core/crypto.mjs';
import { parseCommand, HELP, BOT_NAME, ENVELOPE } from './commands.mjs';

export const SELF_ID = 'ember-jitsi-bot';
const ENVELOPE_OPS = new Set(['ack', 'ask', 'skill', 'review', 'approve', 'mem_list', 'mem_retract', 'end']);
const KIND_ZH = { decision: '决定', todo: '待办', idea: '观点', fact: '公共事实' };
const ERR_ZH = {
  not_acked: '请先在聊天里发「@炉灵 同意」', not_convener: '只有召集人能散会', unknown_draft: '没有这个草稿',
  hash_mismatch: '草稿已经变了,请按最新草稿重新批准', bad_sig: '签名无效', replay: '重复的批准', key_mismatch: '你已用另一把密钥同意过',
  already_released: '草稿已放行', not_allowed: '只有当时批准这条的人能撤回', empty: '目前没有可写进纪要的内容', unknown_item: '没有这个条目',
  bad_request: '请求不完整', unknown_skill: '不支持', internal: '内部错误', bad_key: '公钥无效',
};

export const ANNOUNCE = [
  `大家好,我是${BOT_NAME}(Ember),一个 AI 会议助手。我现在在会里,参会者列表里能看到「${BOT_NAME}」。`,
  '规则(受查塔姆规则启发,非官方):会上说的内容可以带出去,但不说是谁说的。',
  `· 只有在聊天里发「@${BOT_NAME} 同意」的人,我才转写其语音;没同意的人,声音在转写之前就丢掉。`,
  '· 我不录音;原话只在内存里改写成不带名字的账本,散会即清空。',
  '· 纪要先私信给已同意的人审阅,要 k 个不同的参会者批准后才在这里公开,且不带名字和单位。',
  '· 注意:Jitsi 显示名不是身份认证,批准按「不同的 Jitsi 连接」计数。',
  `命令:@${BOT_NAME} 帮助`,
].join('\n');

const b64 = (buf) => Buffer.from(buf).toString('base64');

export function jitsiPort(bridge, { selfId = SELF_ID, log = () => {}, onHost = () => {}, announce = true, convenerName = null } = {}) {
  const handlers = new Map();
  const emit = (ev, ...args) => { for (const fn of handlers.get(ev) ?? []) { try { fn(...args); } catch (e) { log(`port handler ${ev}: ${e.message}`); } } };
  const present = new Map(); // id → {name, hidden}
  const keys = new Map(); // id → {privateKey, pubB64}(托管)
  const selfKeyed = new Set(); // 自持密钥的 endpoint
  let st = { sid: null, k: null, acked: new Set(), convenerId: null };
  let lastAckedCount = -1;
  const drafts = new Map(); // 'D1' → {draftId, draftHash, items}
  const draftShort = new Map(); // draftId → 'D1'
  const mem = new Map(); // 'M1' → itemId
  const memShort = new Map();
  let joined = false;
  let left = false;

  const pub = (text) => Promise.resolve(bridge.sendPublic(text)).catch((e) => log(`公开聊天发送失败: ${e.message}`));
  const priv = (id, text) => Promise.resolve(bridge.sendPrivate(id, text)).catch((e) => log(`私信失败: ${e.message}`));
  const ackedIds = () => [...st.acked].filter((id) => present.has(id));
  const toAcked = (text) => Promise.all(ackedIds().map((id) => priv(id, text)));
  const envelopeTo = (ids, obj) => Promise.all([...ids].filter((id) => selfKeyed.has(id) && present.has(id)).map((id) => priv(id, `${ENVELOPE} ${JSON.stringify(obj)}`)));
  const isHuman = (id) => typeof id === 'string' && id !== '' && id !== selfId && !present.get(id)?.hidden;

  function shortDraft(draftId) {
    if (!draftShort.has(draftId)) { const s = `D${draftShort.size + 1}`; draftShort.set(draftId, s); }
    return draftShort.get(draftId);
  }
  function shortMem(itemId) {
    if (!memShort.has(itemId)) { const s = `M${memShort.size + 1}`; memShort.set(itemId, s); mem.set(s, itemId); }
    return memShort.get(itemId);
  }
  const latestDraft = () => [...drafts.keys()].pop() ?? null;

  function custodialSign(id, message) {
    const k = keys.get(id);
    return edSign(null, Buffer.from(message, 'utf8'), k.privateKey).toString('base64');
  }

  function onChat(id, text, isPrivate) {
    if (!id || id === selfId || left) return;
    if (present.has(id) && present.get(id).hidden) return;
    const c = parseCommand(text, { direct: Boolean(isPrivate) });
    if (!c) return;
    const say = (m) => priv(id, `${BOT_NAME}:${m}`);
    const toEmber = (msg) => emit('message', id, msg);
    switch (c.cmd) {
      case 'help': return priv(id, HELP);
      case 'bad_envelope': return say(c.why === 'public' ? `${ENVELOPE} 信封只能私信给我` : `${ENVELOPE} 信封格式不对`);
      case 'envelope': {
        if (!ENVELOPE_OPS.has(c.msg.t)) return say(`不支持的操作 ${String(c.msg.t).slice(0, 20)}`);
        if (c.msg.t === 'ack' && !keys.has(id)) selfKeyed.add(id);
        return toEmber(c.msg);
      }
      case 'ack': {
        if (selfKeyed.has(id)) return say('你已用自己的密钥同意过');
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
        if (selfKeyed.has(id)) return say(`你用的是自持密钥,请用你的客户端发 ${ENVELOPE} approve`);
        if (!keys.has(id)) return say(ERR_ZH.not_acked);
        const nonce = randomUUID();
        const sig = custodialSign(id, canonicalJSON({ sid: st.sid, draftId: d.draftId, draftHash: d.draftHash, nonce }));
        return toEmber({ t: 'approve', draftId: d.draftId, draftHash: d.draftHash, nonce, sig });
      }
      case 'review': {
        const s = c.draft ?? latestDraft();
        const d = s ? drafts.get(s) : null;
        const it = d?.items[c.item - 1];
        if (!it) return say(ERR_ZH.unknown_item);
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
    const lines = [`【${BOT_NAME}·纪要草稿 ${s}】只私信给已同意的人;需 ${d.k} 位不同的参会者批准才公开。`];
    d.items.forEach((it, i) => {
      lines.push(`${i + 1}. [${KIND_ZH[it.kind] ?? it.kind}] ${it.topic}:${it.text}${it.roleRisk ? `  ⚠可能暴露身份,不处理则不公开(@${BOT_NAME} 保留|泛化|删除 ${s} ${i + 1})` : ''}`);
    });
    lines.push(`批准:@${BOT_NAME} 批准 ${s}(内容一变,已有批准作废)`);
    return lines.join('\n');
  }

  const port = {
    selfId,
    get transcripts() { return false; },
    isHuman,
    nameOf: (id) => present.get(id)?.name ?? '',
    on(ev, fn) { if (!handlers.has(ev)) handlers.set(ev, []); handlers.get(ev).push(fn); return port; },
    // 召集人 = Ember 缺省「第一个进来的人」;convenerName 给定时把同名者排到最前(显示名不是认证,见 README 信任模型)
    participants: () => {
      const xs = [...present].filter(([, p]) => !p.hidden).map(([id, p]) => ({ id, name: p.name ?? '' }));
      if (convenerName) xs.sort((a, b) => Number(b.name === convenerName) - Number(a.name === convenerName));
      return xs;
    },
    async join() {
      if (joined) return;
      joined = true;
      await bridge.join();
      if (announce) await pub(ANNOUNCE);
    },
    async leave() {
      if (left) return;
      left = true;
      for (const k of keys.values()) k.privateKey = null;
      keys.clear();
      try { await bridge.leave(); } catch (e) { log(`离会失败: ${e.message}`); }
    },
    notifyHost(ev) { try { onHost(ev?.type === 'released' ? { type: 'released', items: (ev.itemIds ?? []).length } : { type: ev?.type, on: ev?.on }); } catch { /* */ } },
    async send(obj, toId = null) {
      if (!obj || typeof obj.t !== 'string') return;
      switch (obj.t) {
        case 'state': {
          st = { sid: obj.sid, k: obj.k, acked: new Set((obj.members ?? []).filter((m) => m.acked).map((m) => m.id)), convenerId: obj.convenerId };
          const n = st.acked.size;
          if (n !== lastAckedCount && joined) { lastAckedCount = n; await pub(`${BOT_NAME}:已同意 ${n} 人 · 纪要放行需 ${obj.k} 人批准`); }
          return void await envelopeTo(st.acked, obj);
        }
        case 'answer': {
          const text = `【${BOT_NAME}·回答】(只私信给已同意的人)\n问:${obj.q}\n答:${obj.a}`;
          if (toId) return void await priv(toId, text);
          return void await toAcked(text);
        }
        case 'draft': {
          const d = obj.draft;
          const s = shortDraft(d.draftId);
          drafts.set(s, { draftId: d.draftId, draftHash: d.draftHash, items: d.items.map((i) => ({ id: i.id })), k: d.k });
          await toAcked(renderDraft(s, d));
          return void await envelopeTo(st.acked, obj);
        }
        case 'approvals': {
          const s = shortDraft(obj.draftId);
          await envelopeTo(st.acked, obj);
          if (obj.count > 0) return void await pub(`${BOT_NAME}:纪要草稿 ${s} 已获 ${obj.count}/${obj.k} 人批准${obj.count < obj.k ? ',未放行' : ''}`);
          return undefined;
        }
        case 'released': {
          const s = shortDraft(obj.draftId);
          await envelopeTo(st.acked, obj);
          return void await pub(`【${BOT_NAME}·已放行纪要 ${s}】\n${obj.text}`);
        }
        case 'mem': {
          const lines = [`【${BOT_NAME}·本圈记忆】`, ...(obj.items ?? []).map((i) => `${shortMem(i.id)}. [${KIND_ZH[i.kind] ?? i.kind}] ${i.text}`)];
          if (!(obj.items ?? []).length) lines.push('(空)');
          lines.push(`撤回:@${BOT_NAME} 撤回 M编号(只有当时批准的人能撤回)`);
          if (toId) await priv(toId, lines.join('\n')); else await toAcked(lines.join('\n'));
          return void await envelopeTo(st.acked, obj);
        }
        case 'mem_retracted': {
          const s = memShort.get(obj.itemId) ?? '?';
          return void await pub(`${BOT_NAME}:记忆 ${s} 已撤回,并从所有派生文件中重建删除`);
        }
        case 'error': {
          if (!toId) return undefined;
          if (selfKeyed.has(toId)) await priv(toId, `${ENVELOPE} ${JSON.stringify(obj)}`);
          return void await priv(toId, `${BOT_NAME}:操作 ${obj.op} 未完成 —— ${ERR_ZH[obj.code] ?? obj.code}`);
        }
        case 'ended': {
          const r = obj.receipt ?? {};
          return void await pub(`【${BOT_NAME}】散会。放行 ${r.counts?.releases ?? 0} 份纪要;会中账本已清空。回执 sha256=${String(r.sha256 ?? '').slice(0, 16)}…  ${BOT_NAME}离开会议。`);
        }
        default: return undefined;
      }
    },
  };

  bridge.on('participant', (id, name, hidden) => {
    if (!id || id === selfId) return;
    const was = present.get(id);
    present.set(id, { name: name ?? was?.name ?? '', hidden: Boolean(hidden) });
    if (!hidden && !was) emit('joined', id, name ?? '');
  });
  bridge.on('name', (id, name) => { if (present.has(id)) { present.get(id).name = name; if (!present.get(id).hidden) emit('name', id, name); } });
  bridge.on('left', (id) => {
    const p = present.get(id);
    if (!p) return;
    present.delete(id);
    const k = keys.get(id); if (k) k.privateKey = null;
    keys.delete(id);
    selfKeyed.delete(id);
    if (!p.hidden) emit('left', id);
  });
  bridge.on('audio', (id, pcm, rate) => { if (present.has(id) && !present.get(id).hidden) emit('audio', id, pcm, rate ?? 16000, 1); });
  bridge.on('chat', (id, text, isPrivate) => { void onChat(id, text, isPrivate); });
  bridge.on('disconnected', (why) => emit('disconnected', why));

  // 测试 / 诊断用(不含文字)
  port._debug = () => ({ present: present.size, custodial: keys.size, selfKeyed: selfKeyed.size, drafts: [...drafts.keys()], mem: [...mem.keys()] });
  return port;
}

