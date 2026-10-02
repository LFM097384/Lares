// 转写记录的落盘层(纯存储,不碰 WS)。契约:docs/plans/transcript-bot-contract.md §3/§4。
//
// 两套互不相干的数据:
//
// 1. 明文归档(非 E2EE 圈):DATA_DIR/transcripts/<encodeURIComponent(circleId)>.jsonl
//    一行一条 {seq, ts, userId, name, id, text, startedAt}。只追加。
//    seq 每圈单调递增、跨重启延续:启动后第一次访问某圈时读文件取最大 seq;
//    清空过的圈另在 transcripts/_seq.json 记一个「下限」,清空后 seq 也不回退
//    (客户端拿 seq 当分页游标 / 去重键,回退会让旧缓存与新条目撞号)。
//
// 2. E2EE 密文中继:DATA_DIR/transcript_relay/<enc>.json
//    {members:[userId...], queues:{userId:[{rid,blob,ts}]}}
//    服务器**只见过 blob**(客户端 AES-GCM 加密的 base64),这里没有任何明文。
//    members = 曾进过该圈房间的 userId(持久化),是离线队列的收件人名单。
//    每人上限 5000 条、30 天;已推送但未 ack 的条目照旧留在队列里(下次 hello/join 重推)。
//
// 写盘纪律与 index.js 的 saveRegistry 一致:原子写(tmp + rename),按文件串行化;
// 中继队列写得频繁,所以做「写后合并」:写盘进行中又有变化 → 只再补写一次最新快照。

import crypto from 'node:crypto';
import { mkdir, readFile, writeFile, rename, unlink, appendFile, readdir } from 'node:fs/promises';
import path from 'node:path';

export const TEXT_MAX = 2000;
export const ID_MAX = 200;
export const BLOB_MAX = 8192;
export const PAGE_DEFAULT = 50;
export const PAGE_MAX = 200;
export const QUEUE_MAX_PER_USER = 5000;
export const QUEUE_MAX_AGE_MS = 30 * 24 * 3600_000;
const BASE64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

export function validBlob(blob) {
  return typeof blob === 'string' && blob.length > 0 && blob.length <= BLOB_MAX && blob.length % 4 === 0 && BASE64_RE.test(blob);
}

async function atomicWrite(file, data) {
  await mkdir(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`;
  await writeFile(tmp, data, { mode: 0o600 });
  await rename(tmp, file);
}

async function unlinkQuiet(file) {
  try { await unlink(file); } catch (e) { if (e?.code !== 'ENOENT') throw e; }
}

export function createTranscriptStore({ dataDir, now = () => Date.now() }) {
  const archiveDir = path.join(dataDir, 'transcripts');
  const relayDir = path.join(dataDir, 'transcript_relay');
  const seqFile = path.join(archiveDir, '_seq.json');
  const fileOf = (circleId) => path.join(archiveDir, `${encodeURIComponent(circleId)}.jsonl`);
  const relayFileOf = (circleId) => path.join(relayDir, `${encodeURIComponent(circleId)}.json`);

  // ── 明文归档 ────────────────────────────────────────────────────────────
  let seqFloor = null; // circleId -> 清空时的最后 seq
  const archives = new Map(); // circleId -> Promise<{items, lastSeq, byKey, needsNewline, chain}>

  async function loadSeqFloor() {
    if (seqFloor) return seqFloor;
    try {
      const parsed = JSON.parse(await readFile(seqFile, 'utf8'));
      seqFloor = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
    } catch {
      seqFloor = {};
    }
    return seqFloor;
  }

  function archive(circleId) {
    let p = archives.get(circleId);
    if (!p) {
      p = (async () => {
        const floor = (await loadSeqFloor())[circleId] ?? 0;
        const a = { items: [], lastSeq: Number(floor) || 0, byKey: new Map(), needsNewline: false, chain: Promise.resolve() };
        let raw = '';
        try {
          raw = await readFile(fileOf(circleId), 'utf8');
        } catch (e) {
          if (e?.code !== 'ENOENT') throw e;
        }
        if (raw.length > 0 && !raw.endsWith('\n')) a.needsNewline = true; // 上次写到一半断电:下一行先补换行
        for (const line of raw.split('\n')) {
          if (!line.trim()) continue;
          let it;
          try { it = JSON.parse(line); } catch { continue; } // 半截行跳过
          if (!it || !Number.isInteger(it.seq)) continue;
          a.items.push(it);
          if (it.seq > a.lastSeq) a.lastSeq = it.seq;
          a.byKey.set(`${it.userId}\0${it.id}`, it);
        }
        a.items.sort((x, y) => x.seq - y.seq);
        return a;
      })();
      archives.set(circleId, p);
      p.catch(() => archives.delete(circleId)); // 读失败下次重试
    }
    return p;
  }

  /// 追加一条。同一 (userId, id) 重复追加 = 幂等,返回已有条目(客户端重发不会出双份)。
  async function append(circleId, { userId, name, id, text, startedAt }) {
    const a = await archive(circleId);
    const key = `${userId}\0${id}`;
    const dup = a.byKey.get(key);
    if (dup) return { item: dup, duplicate: true };
    const ts = now();
    const item = {
      seq: ++a.lastSeq,
      ts,
      userId,
      name,
      id,
      text,
      startedAt: Number.isFinite(startedAt) ? Math.trunc(startedAt) : ts,
    };
    a.byKey.set(key, item);
    a.items.push(item);
    const line = `${a.needsNewline ? '\n' : ''}${JSON.stringify(item)}\n`;
    a.needsNewline = false;
    const job = a.chain.then(async () => {
      await mkdir(archiveDir, { recursive: true });
      await appendFile(fileOf(circleId), line, { mode: 0o600 });
    });
    a.chain = job.catch(() => {});
    try {
      await job;
    } catch (e) {
      // 没落盘就不算追加成功:撤回内存里的条目(seq 不回收,避免与可能已部分写入的行撞号)
      a.items.splice(a.items.indexOf(item), 1);
      a.byKey.delete(key);
      throw e;
    }
    return { item, duplicate: false };
  }

  /// 新 → 旧分页。before = seq(不含),limit ≤ 200。
  async function page(circleId, { before, limit } = {}) {
    const a = await archive(circleId);
    const lim = Math.max(1, Math.min(PAGE_MAX, Number.isInteger(limit) ? limit : PAGE_DEFAULT));
    let end = a.items.length; // items 按 seq 升序
    if (Number.isInteger(before)) {
      let lo = 0, hi = a.items.length;
      while (lo < hi) { const mid = (lo + hi) >> 1; if (a.items[mid].seq < before) lo = mid + 1; else hi = mid; }
      end = lo;
    }
    const start = Math.max(0, end - lim);
    const items = a.items.slice(start, end).reverse();
    return { items, more: start > 0 };
  }

  async function clearArchive(circleId, { forget = false } = {}) {
    const a = await archive(circleId);
    await a.chain;
    const floor = await loadSeqFloor();
    if (forget) delete floor[circleId];
    else if (a.lastSeq > 0) floor[circleId] = a.lastSeq;
    await atomicWrite(seqFile, JSON.stringify(floor));
    await unlinkQuiet(fileOf(circleId));
    if (forget) archives.delete(circleId);
    else {
      a.items = [];
      a.byKey = new Map();
      a.needsNewline = false;
    }
  }

  // ── E2EE 密文中继 ─────────────────────────────────────────────────────
  const relays = new Map(); // circleId -> {members:Set, queues:Map<userId, item[]>, writing, dirty}
  let relayLoaded = null;

  function loadAllRelays() {
    relayLoaded ??= (async () => {
      let names = [];
      try { names = await readdir(relayDir); } catch (e) { if (e?.code !== 'ENOENT') throw e; }
      for (const n of names) {
        if (!n.endsWith('.json')) continue;
        let circleId;
        try { circleId = decodeURIComponent(n.slice(0, -5)); } catch { continue; }
        try {
          const parsed = JSON.parse(await readFile(path.join(relayDir, n), 'utf8'));
          const r = emptyRelay();
          for (const u of Array.isArray(parsed.members) ? parsed.members : []) if (typeof u === 'string') r.members.add(u);
          for (const [u, list] of Object.entries(parsed.queues ?? {})) {
            if (Array.isArray(list)) r.queues.set(u, list.filter((x) => x && typeof x.rid === 'string' && typeof x.blob === 'string'));
          }
          relays.set(circleId, r);
          prune(circleId);
        } catch (e) {
          console.error(`[transcript] 中继队列 ${n} 读取失败,已跳过:`, e?.message ?? e);
        }
      }
    })();
    return relayLoaded;
  }

  function emptyRelay() {
    return { members: new Set(), queues: new Map(), writing: null, dirty: false };
  }

  function relay(circleId) {
    let r = relays.get(circleId);
    if (!r) { r = emptyRelay(); relays.set(circleId, r); }
    return r;
  }

  function snapshot(r) {
    return JSON.stringify({ members: [...r.members], queues: Object.fromEntries(r.queues) });
  }

  /// 写后合并:返回「包含本次改动的那次写盘」完成的 promise
  function saveRelay(circleId) {
    const r = relays.get(circleId);
    if (!r) return Promise.resolve();
    r.dirty = true;
    if (r.writing) return r.writing;
    r.writing = (async () => {
      try {
        while (r.dirty) {
          r.dirty = false;
          if (relays.get(circleId) !== r) return; // 已被删除
          await atomicWrite(relayFileOf(circleId), snapshot(r));
        }
      } catch (e) {
        console.error('[transcript] 中继队列写盘失败:', e?.message ?? e);
      } finally {
        r.writing = null;
      }
    })();
    return r.writing;
  }

  function prune(circleId) {
    const r = relays.get(circleId);
    if (!r) return false;
    const cutoff = now() - QUEUE_MAX_AGE_MS;
    let changed = false;
    for (const [u, list] of r.queues) {
      let next = list.filter((x) => x.ts >= cutoff);
      if (next.length > QUEUE_MAX_PER_USER) next = next.slice(next.length - QUEUE_MAX_PER_USER);
      if (next.length !== list.length) changed = true;
      if (next.length === 0) r.queues.delete(u);
      else r.queues.set(u, next);
    }
    return changed;
  }

  async function addMember(circleId, userId) {
    await loadAllRelays();
    const r = relay(circleId);
    if (r.members.has(userId)) return;
    r.members.add(userId);
    await saveRelay(circleId);
  }

  /// 入队:收件人 = 名单里除发送者外的所有人。返回 {rid, ts, item}。
  async function enqueue(circleId, senderUserId, blob) {
    await loadAllRelays();
    const r = relay(circleId);
    const item = { rid: `r_${now().toString(36)}_${crypto.randomBytes(6).toString('hex')}`, blob, ts: now() };
    for (const u of r.members) {
      if (u === senderUserId) continue;
      const list = r.queues.get(u) ?? [];
      list.push(item);
      if (list.length > QUEUE_MAX_PER_USER) list.splice(0, list.length - QUEUE_MAX_PER_USER);
      r.queues.set(u, list);
    }
    prune(circleId);
    await saveRelay(circleId);
    return item;
  }

  async function pending(circleId, userId) {
    await loadAllRelays();
    const r = relays.get(circleId);
    if (!r) return [];
    if (prune(circleId)) saveRelay(circleId);
    return [...(r.queues.get(userId) ?? [])];
  }

  /// 这个人在哪些圈子有待收的密文
  async function circlesWithPending(userId) {
    await loadAllRelays();
    const out = [];
    for (const [c, r] of relays) if ((r.queues.get(userId)?.length ?? 0) > 0) out.push(c);
    return out;
  }

  async function ack(circleId, userId, rids) {
    await loadAllRelays();
    const r = relays.get(circleId);
    const list = r?.queues.get(userId);
    if (!list) return 0;
    const drop = new Set(rids);
    const next = list.filter((x) => !drop.has(x.rid));
    const removed = list.length - next.length;
    if (removed === 0) return 0;
    if (next.length) r.queues.set(userId, next); else r.queues.delete(userId);
    await saveRelay(circleId);
    return removed;
  }

  async function clearQueues(circleId) {
    await loadAllRelays();
    const r = relays.get(circleId);
    if (!r) return;
    r.queues.clear();
    await saveRelay(circleId);
  }

  /// 解散圈子:归档、seq 下限、中继(含名单)全部删除
  async function deleteCircle(circleId) {
    await loadAllRelays();
    await clearArchive(circleId, { forget: true });
    const r = relays.get(circleId);
    relays.delete(circleId);
    if (r?.writing) await r.writing.catch(() => {});
    await unlinkQuiet(relayFileOf(circleId));
  }

  return {
    append, page, clearArchive, loadAllRelays,
    addMember, enqueue, pending, circlesWithPending, ack, clearQueues, deleteCircle,
    // 测试 / 调试
    paths: { archiveDir, relayDir, fileOf, relayFileOf },
  };
}
