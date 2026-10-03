// 功能开关 + 用途预设(契约 docs/plans/features-purpose-contract.md §1-§3)。
//
// 同 transcript_ws.js:index.js 在主 switch 之前调 handle();返回 true = 这条消息归这里管。
// 依赖全部注入:圈设置走 d.settings() / d.saveSettingsNow(),插件表走 d.plugins 的批量接口。

import { FEATURE_KEYS, BUILTIN_PURPOSES, validatePurpose } from './purpose.js';
import { FOCUS_ID } from './plugins.js';
import { allowPrivateFrom } from './plugin_webhooks.js';

export { FEATURE_KEYS };
/// 存在 circleSettings[cid].features 里的键;transcript / focus 是派生的,不另存
export const STORED_KEYS = Object.freeze(['captions', 'voiceNotes', 'map', 'recording', 'plugins', 'p2p', 'devTools']);
/// 新注册圈的默认(§1)
export const NEW_CIRCLE_FEATURES = Object.freeze({
  captions: true, voiceNotes: true, plugins: true, map: false, recording: false, p2p: false, devTools: false,
});

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const clone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));

/**
 * 解析出 9 个功能键的全量布尔表。
 * 老圈(没有 features)/ 缺的键 → true;transcript 取 settings.transcript;focus 由调用方给(插件已装且启用)。
 */
export function resolveFeatures(entry, { focusOn = false } = {}) {
  const stored = isObj(entry?.features) ? entry.features : {};
  const out = {};
  for (const k of FEATURE_KEYS) {
    if (k === 'transcript') out[k] = entry?.transcript === true;
    else if (k === 'focus') out[k] = focusOn === true;
    else out[k] = stored[k] !== false;
  }
  return out;
}

/// 下发用的用途摘要 {id, name, icon?, builtin} | null
export function purposeView(entry) {
  const p = entry?.purpose;
  if (!isObj(p) || typeof p.id !== 'string') return null;
  return { id: p.id, name: p.name, ...(p.icon ? { icon: p.icon } : {}), builtin: p.builtin === true };
}

/**
 * @param {object} d
 *   send(ws,msg), settings() -> circleSettings 对象, saveSettingsNow() -> Promise(原子落盘),
 *   registeredCircle(id), ownerKeyOk(id,key),
 *   plugins (createPlugins 的返回值:isEnabled / installOf / planPurposePlugins / issueTokens / revokeTokens /
 *            commitPlan / restore / announce / exportItems / savePlugins),
 *   broadcastLobbySummary(id), broadcastCircleSettings(id), env
 */
export function createFeaturesWs(d) {
  const allowPrivate = allowPrivateFrom(d.env ?? process.env);
  const cidOf = (msg) => (typeof msg.circleId === 'string' ? msg.circleId : '');
  const locks = new Map(); // circleId -> Promise:同一个圈的改动串行,免得快照互相覆盖

  const focusOn = (circleId) => d.plugins.isEnabled(circleId, FOCUS_ID);
  const featuresOf = (circleId) => resolveFeatures(d.settings()[circleId], { focusOn: focusOn(circleId) });
  const isOn = (circleId, key) => featuresOf(circleId)[key] === true;

  function withLock(circleId, fn) {
    const prev = locks.get(circleId) ?? Promise.resolve();
    const run = prev.catch(() => {}).then(fn);
    const tail = run.catch(() => {});
    locks.set(circleId, tail);
    tail.then(() => { if (locks.get(circleId) === tail) locks.delete(circleId); });
    return run;
  }

  function ownerGate(ws, session, msg, op) {
    const circleId = cidOf(msg);
    const fail = (reason, detail) => { d.send(ws, { t: 'owner_error', op, circleId, reason, ...(detail ? { detail } : {}) }); return null; };
    if (!session.userId) return fail('say_hello_first');
    if (!d.registeredCircle(circleId)) return fail('not_registered');
    if (!d.ownerKeyOk(circleId, msg.ownerKey)) return fail('not_owner');
    return { circleId, fail };
  }

  /// features.focus 没配 lares.focus 项时,补一项(关:只在已装时停用;开:没装就装)
  function focusItem(circleId, focus) {
    if (focus === true) return { id: FOCUS_ID, enabled: true };
    if (focus === false && d.plugins.installOf(circleId, FOCUS_ID)) return { id: FOCUS_ID, enabled: false };
    return null;
  }

  /// 把存储型键 + transcript 合进圈设置条目(老圈第一次改时把「全开」固化下来)
  function mergeFeatures(entry, features) {
    const stored = { ...Object.fromEntries(STORED_KEYS.map((k) => [k, true])), ...(isObj(entry.features) ? entry.features : {}) };
    for (const k of STORED_KEYS) if (has(features, k)) stored[k] = features[k];
    entry.features = stored;
    if (has(features, 'transcript')) entry.transcript = features.transcript;
  }

  /**
   * 原子应用:先算插件计划(全部校验 + 抓取)→ 签 token → 内存里改圈设置与插件表 → 两份都落盘。
   * 任一步失败:两份回滚到快照、吊销本次签的 token。
   * @returns {Promise<{ok:true, plan, snap} | {ok:false, reason, detail?}>}
   */
  async function applyAtomic(circleId, { pluginItems, allowThirdParty, mutate }) {
    const planned = await d.plugins.planPurposePlugins(circleId, pluginItems, { allowThirdParty });
    if (!planned.ok) return planned;
    const plan = planned.plan;
    try {
      await d.plugins.issueTokens(circleId, plan);
    } catch (e) {
      console.error('[features] 签发插件 token 失败:', e?.message ?? e);
      return { ok: false, reason: 'save_failed' };
    }
    const all = d.settings();
    const hadEntry = has(all, circleId);
    const settingsSnap = clone(all[circleId]);
    const committed = d.plugins.commitPlan(circleId, plan);
    if (!committed.ok) {
      await d.plugins.revokeTokens(plan);
      return committed;
    }
    const entry = clone(all[circleId]) ?? {};
    mutate(entry);
    all[circleId] = entry;
    const touchedPlugins = plan.length > 0;
    const results = await Promise.allSettled([
      d.saveSettingsNow(),
      touchedPlugins ? d.plugins.savePlugins() : Promise.resolve(),
    ]);
    const failed = results.find((r) => r.status === 'rejected');
    if (failed) {
      console.error('[features] 落盘失败,回滚:', failed.reason?.message ?? failed.reason);
      if (hadEntry) all[circleId] = settingsSnap; else delete all[circleId];
      d.plugins.restore(circleId, committed.snap);
      await d.plugins.revokeTokens(plan);
      // 尽力把磁盘也拉回快照(可能有一份已经写成功了)
      d.saveSettingsNow().catch(() => {});
      if (touchedPlugins) d.plugins.savePlugins().catch(() => {});
      return { ok: false, reason: 'save_failed' };
    }
    return { ok: true, plan, snap: committed.snap };
  }

  function broadcastAfter(circleId, plan, snap) {
    const pluginsChanged = d.plugins.announce(circleId, plan, snap, { broadcast: true });
    // announce 的插件列表广播已带摘要 + 圈设置;插件没变就自己发
    if (!pluginsChanged) {
      d.broadcastLobbySummary(circleId);
      d.broadcastCircleSettings(circleId);
    }
  }

  async function featuresSet(ws, session, msg) {
    const g = ownerGate(ws, session, msg, 'circle_features_set');
    if (!g) return;
    const { circleId, fail } = g;
    const f = msg.features;
    if (!isObj(f) || Object.keys(f).length === 0) return fail('bad_request');
    for (const [k, v] of Object.entries(f)) {
      if (!FEATURE_KEYS.includes(k) || typeof v !== 'boolean') return fail('bad_request', `features.${String(k).slice(0, 40)}`);
    }
    await withLock(circleId, async () => {
      const item = has(f, 'focus') ? focusItem(circleId, f.focus) : null;
      const r = await applyAtomic(circleId, {
        pluginItems: item ? [item] : [],
        allowThirdParty: true, // 只可能碰内置
        mutate: (entry) => mergeFeatures(entry, f),
      });
      if (!r.ok) return fail(r.reason, r.detail);
      d.send(ws, { t: 'owner_ok', op: 'circle_features_set', circleId });
      broadcastAfter(circleId, r.plan, r.snap);
    });
  }

  async function purposeApply(ws, session, msg) {
    const g = ownerGate(ws, session, msg, 'circle_purpose_apply');
    if (!g) return;
    const { circleId, fail } = g;
    let purpose;
    let builtin = false;
    if (typeof msg.purpose === 'string') {
      if (!has(BUILTIN_PURPOSES, msg.purpose)) return fail('bad_purpose', 'purpose:unknown_builtin');
      const v = validatePurpose(clone(BUILTIN_PURPOSES[msg.purpose]), { allowPrivate });
      if (!v.ok) return fail(v.reason, v.detail); // 不该发生
      purpose = v.purpose;
      builtin = true;
    } else {
      const v = validatePurpose(msg.purpose, { allowPrivate });
      if (!v.ok) return fail(v.reason, v.detail);
      purpose = v.purpose;
    }
    await withLock(circleId, async () => {
      const feats = purpose.features;
      const items = [...purpose.plugins];
      const hasFocusItem = items.some((it) => it.id === FOCUS_ID);
      if (!hasFocusItem && has(feats, 'focus')) {
        const it = focusItem(circleId, feats.focus);
        if (it) items.push(it);
      }
      // 看「应用后」的开关:用途自己写了 plugins 就按它,没写按圈子当前
      const allowThirdParty = has(feats, 'plugins') ? feats.plugins : isOn(circleId, 'plugins');
      const s = purpose.settings;
      const r = await applyAtomic(circleId, {
        pluginItems: items,
        allowThirdParty,
        mutate: (entry) => {
          mergeFeatures(entry, feats);
          if (has(s, 'transcript')) entry.transcript = s.transcript;
          if (has(s, 'knockRequired')) entry.knockRequired = s.knockRequired;
          entry.purpose = {
            id: purpose.id,
            name: purpose.name,
            ...(purpose.icon ? { icon: purpose.icon } : {}),
            ...(purpose.description ? { description: purpose.description } : {}),
            builtin,
            ...(has(s, 'e2eeWarning') ? { e2eeWarning: s.e2eeWarning } : {}),
          };
        },
      });
      if (!r.ok) return fail(r.reason, r.detail);
      const secrets = r.plan
        .filter((p) => p.token)
        .map((p) => ({ pluginId: p.pluginId, token: p.token, webhookSecret: p.webhookSecret }));
      d.send(ws, { t: 'purpose_applied', circleId, purpose: purposeView(d.settings()[circleId]), secrets });
      d.send(ws, { t: 'owner_ok', op: 'circle_purpose_apply', circleId });
      broadcastAfter(circleId, r.plan, r.snap);
    });
  }

  /// 当前实际配置导出成用途 JSON(§3.4):不含 token / 密钥 / 共享状态
  function exportPurpose(circleId) {
    const entry = d.settings()[circleId] ?? {};
    const p = isObj(entry.purpose) ? entry.purpose : null;
    return {
      v: 1,
      id: p?.id ?? 'custom',
      name: p?.name ?? '自定义',
      ...(p?.icon ? { icon: p.icon } : {}),
      ...(p?.description ? { description: p.description } : {}),
      features: featuresOf(circleId),
      plugins: d.plugins.exportItems(circleId),
      settings: {
        transcript: entry.transcript === true,
        knockRequired: entry.knockRequired === true,
        e2eeWarning: p?.e2eeWarning === true,
      },
    };
  }

  async function handle(ws, session, msg) {
    switch (msg.t) {
      case 'circle_features_set': await featuresSet(ws, session, msg); return true;
      case 'circle_purpose_apply': await purposeApply(ws, session, msg); return true;
      case 'circle_purpose_export': {
        const g = ownerGate(ws, session, msg, 'circle_purpose_export');
        if (!g) return true;
        d.send(ws, { t: 'circle_purpose', circleId: g.circleId, purpose: exportPurpose(g.circleId) });
        return true;
      }
    }
    return false;
  }

  return { handle, isOn, featuresOf, exportPurpose };
}
