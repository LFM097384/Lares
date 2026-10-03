// 用途(purpose):功能 + 插件 + 圈设置的打包(契约 docs/plans/features-purpose-contract.md §3)。
//
// 纯函数:结构校验、内置用途、分享码编解码。插件存在性 / 抓 manifest / 解析 webhook 地址
// 不在这里 —— 那要看圈子当前状态,由 plugins.js 的 planPlugins 做。

import { gzipSync, gunzipSync } from 'node:zlib';
import { validateManifest, CONFIG_MAX } from './plugins.js';

/// 9 个功能键(定义在这里,features.js 再导出,免得两个模块互相 import)
export const FEATURE_KEYS = Object.freeze(['captions', 'transcript', 'voiceNotes', 'map', 'recording', 'plugins', 'focus', 'p2p', 'devTools']);

export const PURPOSE_MAX = 32 * 1024;
export const PURPOSE_PLUGINS_MAX = 10;
export const CODE_PREFIX = 'lares-purpose:';
export const CODE_INFLATE_MAX = 64 * 1024;

const TOP_KEYS = new Set(['v', 'id', 'name', 'icon', 'description', 'features', 'plugins', 'settings']);
const ITEM_KEYS = new Set(['id', 'manifest', 'manifestUrl', 'enabled', 'config']);
const SETTINGS_KEYS = new Set(['transcript', 'knockRequired', 'e2eeWarning']);
const ID_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const FOCUS_ID = 'lares.focus';

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const cpLen = (s) => [...s].length;
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

/**
 * 结构校验用途 JSON(§3.1)。
 * @returns {{ok:true, purpose:object} | {ok:false, reason:'bad_purpose'|'bad_manifest', detail:string}}
 *   purpose 为规范化后的副本:{v:1, id, name, icon?, description?, features, plugins:[{id|manifest|manifestUrl, enabled, config?}], settings}
 */
export function validatePurpose(p, { allowPrivate = false } = {}) {
  const bad = (detail) => ({ ok: false, reason: 'bad_purpose', detail });
  if (!isObj(p)) return bad('$:not_object');
  let size;
  try { size = Buffer.byteLength(JSON.stringify(p), 'utf8'); } catch { return bad('$:not_json'); }
  if (size > PURPOSE_MAX) return bad('$:too_large');
  for (const k of Object.keys(p)) if (!TOP_KEYS.has(k)) return bad(`${k}:unknown_key`);
  if (has(p, 'v') && p.v !== 1) return bad('v:unsupported');
  if (typeof p.id !== 'string' || !ID_RE.test(p.id)) return bad('id:invalid');
  if (typeof p.name !== 'string' || !p.name.trim() || cpLen(p.name) > 24) return bad('name:invalid');
  if (has(p, 'icon') && (typeof p.icon !== 'string' || cpLen(p.icon) > 8)) return bad('icon:invalid');
  if (has(p, 'description') && (typeof p.description !== 'string' || cpLen(p.description) > 200)) return bad('description:invalid');

  const features = {};
  if (has(p, 'features')) {
    if (!isObj(p.features)) return bad('features:not_object');
    for (const [k, v] of Object.entries(p.features)) {
      if (!FEATURE_KEYS.includes(k)) return bad(`features.${k}:unknown_key`);
      if (typeof v !== 'boolean') return bad(`features.${k}:not_bool`);
      features[k] = v;
    }
  }

  const settings = {};
  if (has(p, 'settings')) {
    if (!isObj(p.settings)) return bad('settings:not_object');
    for (const [k, v] of Object.entries(p.settings)) {
      if (!SETTINGS_KEYS.has(k)) return bad(`settings.${k}:unknown_key`);
      if (typeof v !== 'boolean') return bad(`settings.${k}:not_bool`);
      settings[k] = v;
    }
  }
  if (has(features, 'transcript') && has(settings, 'transcript') && features.transcript !== settings.transcript) {
    return bad('settings.transcript:conflict');
  }

  const plugins = [];
  if (has(p, 'plugins')) {
    if (!Array.isArray(p.plugins)) return bad('plugins:not_array');
    if (p.plugins.length > PURPOSE_PLUGINS_MAX) return bad(`plugins:max_${PURPOSE_PLUGINS_MAX}`);
    const seen = new Set();
    for (let i = 0; i < p.plugins.length; i++) {
      const it = p.plugins[i];
      const at = `plugins[${i}]`;
      if (!isObj(it)) return bad(`${at}:not_object`);
      for (const k of Object.keys(it)) if (!ITEM_KEYS.has(k)) return bad(`${at}.${k}:unknown_key`);
      const sources = ['id', 'manifest', 'manifestUrl'].filter((k) => has(it, k));
      if (sources.length !== 1) return bad(`${at}:need_exactly_one_of_id_manifest_manifestUrl`);
      if (has(it, 'enabled') && typeof it.enabled !== 'boolean') return bad(`${at}.enabled:not_bool`);
      const out = { enabled: it.enabled !== false };
      if (has(it, 'config')) {
        if (!isObj(it.config)) return bad(`${at}.config:not_object`);
        if (Buffer.byteLength(JSON.stringify(it.config), 'utf8') > CONFIG_MAX) return bad(`${at}.config:too_large`);
        out.config = it.config;
      }
      let pid = null;
      if (sources[0] === 'id') {
        if (typeof it.id !== 'string' || !it.id || it.id.length > 64) return bad(`${at}.id:invalid`);
        out.id = pid = it.id;
      } else if (sources[0] === 'manifest') {
        const v = validateManifest(it.manifest, { allowPrivate });
        if (!v.ok) return { ok: false, reason: v.reason, detail: `${at}:${v.detail}` };
        out.manifest = v.manifest;
        pid = v.manifest.id;
      } else {
        if (typeof it.manifestUrl !== 'string' || !it.manifestUrl || it.manifestUrl.length > 2048) return bad(`${at}.manifestUrl:invalid`);
        out.manifestUrl = it.manifestUrl;
      }
      if (pid !== null) {
        if (seen.has(pid)) return bad(`${at}:duplicate`);
        seen.add(pid);
      }
      if (pid === FOCUS_ID && has(features, 'focus') && features.focus !== out.enabled) return bad(`${at}.enabled:conflict_with_features.focus`);
      plugins.push(out);
    }
  }

  return {
    ok: true,
    purpose: {
      v: 1,
      id: p.id,
      name: p.name.trim(),
      ...(has(p, 'icon') && p.icon ? { icon: p.icon } : {}),
      ...(has(p, 'description') && p.description ? { description: p.description } : {}),
      features,
      plugins,
      settings,
    },
  };
}

// ── 内置用途(§3.2)──
// map / recording / p2p / devTools 一律不碰:那是圈主单独决定的事。
export const BUILTIN_PURPOSES = Object.freeze({
  chat: Object.freeze({
    v: 1, id: 'chat', name: '闲聊', icon: '💬',
    features: { captions: false, transcript: false, voiceNotes: true, focus: false },
  }),
  study: Object.freeze({
    v: 1, id: 'study', name: '学习', icon: '📚',
    features: { captions: false, transcript: false, voiceNotes: false, focus: true },
    plugins: [{ id: FOCUS_ID, enabled: true }],
  }),
  meeting: Object.freeze({
    v: 1, id: 'meeting', name: '开会', icon: '📝',
    features: { captions: true, transcript: true, voiceNotes: false, focus: false, plugins: true },
    settings: { e2eeWarning: true },
  }),
});

// ── 分享码(§3.5)──
/// `lares-purpose:` + base64url(gzip(UTF-8 JSON)),无填充
export function encodePurposeCode(obj) {
  const json = Buffer.from(JSON.stringify(obj), 'utf8');
  return CODE_PREFIX + gzipSync(json).toString('base64url');
}

/// @returns {{ok:true, purpose:any} | {ok:false, reason:'bad_purpose', detail:string}}  —— 只解码,不校验结构
export function decodePurposeCode(str) {
  const bad = (detail) => ({ ok: false, reason: 'bad_purpose', detail: `code:${detail}` });
  if (typeof str !== 'string') return bad('not_string');
  const s = str.trim();
  if (!s.startsWith(CODE_PREFIX)) return bad('prefix');
  const body = s.slice(CODE_PREFIX.length);
  if (!body || body.length > CODE_INFLATE_MAX * 2 || !/^[A-Za-z0-9_-]+$/.test(body)) return bad('base64url');
  let raw;
  try {
    raw = gunzipSync(Buffer.from(body, 'base64url'), { maxOutputLength: CODE_INFLATE_MAX });
  } catch (e) {
    return bad(e?.code === 'ERR_BUFFER_TOO_LARGE' || e instanceof RangeError ? 'too_large' : 'gzip');
  }
  if (raw.length > PURPOSE_MAX) return bad('too_large');
  let purpose;
  try {
    purpose = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(raw));
  } catch { return bad('json'); }
  return { ok: true, purpose };
}
