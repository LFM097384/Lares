// ember-jitsi · 会议聊天命令解析(纯函数,无副作用)。
// 公开聊天里必须 @炉灵(或 @Ember / 「炉灵，」开头)才算命令;发给炉灵的私信不需要 @。
// 另有机读信封 `EMBER1 {json}`:自持密钥的客户端用它直接发 Ember 协议消息(ack / approve …)。
export const BOT_NAME = '炉灵';
export const ENVELOPE = 'EMBER1';
const MENTION = /^\s*(?:[@＠]\s*(?:炉灵|ember)|(?:炉灵|ember)\s*[,，:：])\s*/i;

const REVIEW = new Map([['保留', 'keep'], ['keep', 'keep'], ['泛化', 'generalise'], ['generalise', 'generalise'], ['generalize', 'generalise'], ['删除', 'cut'], ['删', 'cut'], ['cut', 'cut']]);
const DRAFT_ID = /^d\d+$/i;
const MEM_ID = /^m\d+$/i;

/**
 * @param {string} text   原始聊天文字
 * @param {{direct?: boolean}} [o]  direct = 私信给炉灵(不需要 @)
 * @returns {null | {cmd: string, [k: string]: any}}  null = 不是给炉灵的命令(普通聊天,炉灵不看)
 */
export function parseCommand(text, { direct = false } = {}) {
  let s = String(text ?? '').replace(/\u200b/g, '').trim();
  if (!s) return null;
  if (s.startsWith(`${ENVELOPE} `) || s.startsWith(`${ENVELOPE}{`)) {
    if (!direct) return { cmd: 'bad_envelope', why: 'public' }; // 信封只走私信
    try {
      const msg = JSON.parse(s.slice(ENVELOPE.length).trim());
      if (!msg || typeof msg !== 'object' || typeof msg.t !== 'string') return { cmd: 'bad_envelope', why: 'shape' };
      return { cmd: 'envelope', msg };
    } catch { return { cmd: 'bad_envelope', why: 'json' }; }
  }
  const m = MENTION.exec(s);
  if (m) s = s.slice(m[0].length).trim();
  else if (!direct) return null;
  if (!s) return { cmd: 'help' };
  const [head0, ...rest] = s.split(/\s+/);
  const head = head0.replace(/[:：,，。.!！?？]+$/, '').toLowerCase();
  const tail = s.slice(head0.length).trim();
  switch (head) {
    case '同意': case '我同意': case 'ack': case 'agree': return { cmd: 'ack' };
    case '问': case '提问': case 'ask': case '?': case '？':
      return tail ? { cmd: 'ask', q: tail } : { cmd: 'help' };
    case '纪要': case '出纪要': case 'minutes': return { cmd: 'minutes' };
    case '批准': case '签名': case 'approve': {
      const d = rest.find((x) => DRAFT_ID.test(x));
      return { cmd: 'approve', draft: d ? d.toUpperCase() : null };
    }
    case '记忆': case 'memory': case 'mem': return { cmd: 'mem_list' };
    case '撤回': case 'retract': {
      const id = rest.find((x) => MEM_ID.test(x));
      return id ? { cmd: 'mem_retract', item: id.toUpperCase() } : { cmd: 'help' };
    }
    case '结束': case '散会': case 'end': return { cmd: 'end' };
    case '帮助': case 'help': return { cmd: 'help' };
    default: break;
  }
  if (REVIEW.has(head)) {
    const d = rest.find((x) => DRAFT_ID.test(x));
    const n = Number(rest.find((x) => /^\d+$/.test(x)));
    if (!Number.isInteger(n) || n < 1) return { cmd: 'help' };
    return { cmd: 'review', action: REVIEW.get(head), draft: d ? d.toUpperCase() : null, item: n };
  }
  // 「@炉灵 <一句问话>」也当提问
  return { cmd: 'ask', q: s };
}

export const HELP = [
  `【${BOT_NAME} 命令】公开聊天里先 @${BOT_NAME};私信给我不用 @`,
  `@${BOT_NAME} 同意 —— 同意规则(之后我才转写你的语音)`,
  `@${BOT_NAME} 问 <问题> —— 问刚才讨论的内容(答案私信给已同意的人)`,
  `@${BOT_NAME} 纪要 —— 生成纪要草稿(私信给已同意的人审阅)`,
  `@${BOT_NAME} 批准 D1 —— 批准草稿;够 k 人才在本聊天公开`,
  `@${BOT_NAME} 保留|泛化|删除 D1 <序号> —— 处理标 ⚠ 的条目(会清空已有批准)`,
  `@${BOT_NAME} 记忆 / 撤回 M1 —— 查看 / 撤回已放行的记忆(只有当时的批准人能撤回)`,
  `@${BOT_NAME} 结束 —— 散会(只有召集人)`,
].join('\n');
