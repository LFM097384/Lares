// 机器人 token 存储。契约 §5:DATA_DIR/bot_tokens.json 只存 sha256,明文只在创建时回给圈主一次。
//
// token 形如 lrb_<base64url(32 字节随机)>。查找按 sha256 精确匹配(定长哈希比较,
// 不会因前缀不同提早返回,外部无从靠计时猜 token)。

import crypto from 'node:crypto';
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import path from 'node:path';

export const BOT_NAME_MAX = 32;
export const BOT_TOKENS_PER_CIRCLE_MAX = 20;
const TOKEN_RE = /^lrb_[A-Za-z0-9_-]{43}$/;

const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');

export function createBotTokenStore({ dataDir }) {
  const file = path.join(dataDir, 'bot_tokens.json');
  /** @type {Array<{id,circleId,name,sha256,createdAt}>} */
  let items = [];
  let byHash = new Map();
  let saving = Promise.resolve();

  function reindex() {
    byHash = new Map(items.map((t) => [t.sha256, t]));
  }

  async function load() {
    try {
      const parsed = JSON.parse(await readFile(file, 'utf8'));
      items = (Array.isArray(parsed?.tokens) ? parsed.tokens : []).filter(
        (t) => t && typeof t.id === 'string' && typeof t.circleId === 'string' && /^[0-9a-f]{64}$/.test(t.sha256),
      );
    } catch (e) {
      if (e?.code !== 'ENOENT') console.error('[bot] bot_tokens.json 读取失败:', e?.message ?? e);
      items = [];
    }
    reindex();
  }

  function save() {
    const data = JSON.stringify({ tokens: items }, null, 2);
    saving = saving.catch(() => {}).then(async () => {
      await mkdir(path.dirname(file), { recursive: true });
      const tmp = `${file}.${process.pid}.tmp`;
      await writeFile(tmp, data, { mode: 0o600 });
      await rename(tmp, file);
    });
    return saving;
  }

  /// 返回 {token, record}。token 明文只出现在这一次返回里。
  async function create(circleId, name) {
    if (items.filter((t) => t.circleId === circleId).length >= BOT_TOKENS_PER_CIRCLE_MAX) {
      throw Object.assign(new Error('too_many'), { reason: 'too_many' });
    }
    const token = `lrb_${crypto.randomBytes(32).toString('base64url')}`;
    const record = {
      id: `b_${crypto.randomBytes(8).toString('hex')}`,
      circleId,
      name,
      sha256: sha256(token),
      createdAt: Date.now(),
    };
    items.push(record);
    reindex();
    await save();
    return { token, record };
  }

  function list(circleId) {
    return items.filter((t) => t.circleId === circleId).map(({ id, name, createdAt }) => ({ id, name, createdAt }));
  }

  /// 撤销;返回被删的记录或 null
  async function revoke(circleId, id) {
    const rec = items.find((t) => t.circleId === circleId && t.id === id);
    if (!rec) return null;
    items = items.filter((t) => t !== rec);
    reindex();
    await save();
    return rec;
  }

  /// 删除某圈全部 token,返回被删记录
  async function deleteCircle(circleId) {
    const gone = items.filter((t) => t.circleId === circleId);
    if (!gone.length) return [];
    items = items.filter((t) => t.circleId !== circleId);
    reindex();
    await save();
    return gone;
  }

  function verify(token) {
    if (typeof token !== 'string' || !TOKEN_RE.test(token)) return null;
    return byHash.get(sha256(token)) ?? null;
  }

  return { load, create, list, revoke, deleteCircle, verify, file };
}
