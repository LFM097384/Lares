// 隐名之约 v2 · 记忆接口(AGENT-V2.md §7)。agent 只经这一层碰记忆:
//
//   remember(items, {sid, draftId, approvals, k?, approverIds?}) -> Promise<[{id, text, kind, …}]>  只收已放行条目
//   recall(q, {limit})            -> Promise<items>   房内用(answer)
//   recallForOutput(q, {limit})   -> Promise<items>   出门用(防拼图:mosaic + L4,拼得出人的直接丢)
//   consolidate()                 -> Promise<void>    合并摘要(文件记忆实现;v1 内存后端为空操作)
//   retract(itemId, by)           -> Promise<bool>
//   list()                        -> Promise<items>
//
// 后端优先 ember/core/filememory.mjs 的 createFileMemory({dir, circleId, roster, llm});
// 不存在(或还是桩)时退回 core/memory.mjs + jsonFileStorage(<dir>/memory.json),dir 缺省为内存存储。
// 注意:传给后端的 llm 恒为 null —— core 的 L4 攻击提示里带名单姓名,LLM 不能看见(§4「LLM 永远看不到」)。
import path from 'node:path';
import { mkdirSync } from 'node:fs';
import { createMemory, jsonFileStorage, memoryStorage } from '../core/memory.mjs';

const call = async (fn, ...a) => (typeof fn === 'function' ? await fn(...a) : undefined);

export async function openMemory({ dir = null, circleId, roster = () => [], backend = 'auto', log = () => {} } = {}) {
  let impl = null;
  let kind = 'core';
  if (backend !== 'core') {
    try {
      const fm = await import('../core/filememory.mjs');
      if (typeof fm.createFileMemory === 'function' && dir) {
        impl = await fm.createFileMemory({ dir, circleId, roster, llm: null });
        kind = 'file';
      }
    } catch (e) { if (backend === 'file') throw e; }
  }
  if (!impl) {
    let storage = memoryStorage();
    if (dir) {
      mkdirSync(dir, { recursive: true });
      storage = jsonFileStorage(path.join(dir, 'memory.json'));
    }
    impl = createMemory({ circleId, storage, roster, llm: null });
    if (dir) log('记忆:filememory 未就绪,退回 core/memory.mjs(memory.json)');
  }
  return wrapMemory(impl, { kind, roster });
}

/// 任意后端 → 统一接口。core/memory 没有 remember/consolidate:用 addRelease / 空操作补齐。
export function wrapMemory(impl, { kind = 'custom', roster = () => [] } = {}) {
  const rost = () => { try { return (typeof roster === 'function' ? roster() : roster) || []; } catch { return []; } };
  return Object.freeze({
    kind,
    async remember(items, { sid, draftId, approvals, k = null, approverIds = [] } = {}) {
      const clean = (items || []).map((x) => ({ text: String(x?.text ?? ''), kind: x?.kind })).filter((x) => x.text.trim());
      if (!clean.length) return [];
      if (typeof impl.remember === 'function') return (await impl.remember(clean, { sid, draftId, approvals, k, approverIds })) ?? [];
      return impl.addRelease({ sid, draftId, approvals, k, items: clean, approverIds });
    },
    async recall(q, { limit = 5 } = {}) { return (await call(impl.recall?.bind(impl), q, { limit })) ?? []; },
    async recallForOutput(q, { limit = 5 } = {}) {
      return (await call(impl.recallForOutput?.bind(impl), q, { limit, roster: rost(), llm: null })) ?? [];
    },
    async consolidate() { await call(impl.consolidate?.bind(impl)); },
    async retract(itemId, by) {
      // filememory: retract(id, {by}) → {ok, code};core/memory: retract(id, by) → bool
      const r = await call(impl.retract?.bind(impl), itemId, kind === 'file' ? { by } : by);
      return typeof r === 'object' && r !== null ? r.ok === true : Boolean(r);
    },
    async list() { return ((await call(impl.list?.bind(impl))) ?? []).filter((x) => x && !x.retracted); },
  });
}
