// 插件:manifest 校验 / 内置注册表 / 安装存储 / 共享状态 / 信令消息(契约 docs/plans/plugin-focus-contract.md §0-§5)。
//
// 同 transcript_ws.js:index.js 在主 switch 之前调 handle();返回 true = 这条消息归这里管。
// 依赖全部注入,本模块不碰 circles / registry 这些全局表。

import crypto from 'node:crypto';
import { mkdir, writeFile, rename, readFile } from 'node:fs/promises';
import { writeFileSync, renameSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { TokenBuckets } from './ratelimit.js';
import { normalizeFocusConfig, FOCUS_DEFAULTS } from './focus.js';
import { normalizeAiVoiceConfig, AI_VOICE_SETTINGS_SCHEMA } from './ai_voice_config.js'; // lares.ai-voice
import { resolveSafe, fetchManifest, newWebhookSecret, allowPrivateFrom } from './plugin_webhooks.js';

export const MANIFEST_MAX = 16 * 1024;
export const SETTINGS_SCHEMA_MAX = 8 * 1024;
export const CONFIG_MAX = 4 * 1024;
export const PATCH_MAX = 16 * 1024;
export const STATE_MAX = 64 * 1024;
export const PLUGINS_PER_CIRCLE_MAX = 10;
export const FOCUS_ID = 'lares.focus';

export const PERMISSIONS = Object.freeze([
  'circle:read', 'members:read', 'chat:read', 'chat:send', 'captions:read', 'captions:send',
  'transcript:read', 'state:read', 'state:write', 'storage', 'focus:read',
]);
/// webhook 事件 → 所需权限
export const EVENT_PERMISSION = Object.freeze({
  transcript: 'transcript:read',
  join: 'members:read',
  leave: 'members:read',
  presence: 'members:read',
  chat: 'chat:read',
  plugin_state: 'state:read',
  focus: 'focus:read',
});
export const LIFECYCLE_EVENTS = Object.freeze(['installed', 'enabled', 'config', 'uninstalled']);

const ID_RE = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?){1,7}$/;
const VERSION_RE = /^[0-9A-Za-z.+-]+$/;
const TOP_KEYS = new Set(['id', 'name', 'version', 'description', 'author', 'homepage', 'entry', 'permissions', 'webhook', 'settingsSchema']);

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const jsonSize = (v) => Buffer.byteLength(JSON.stringify(v), 'utf8');
const strLen = (s) => [...s].length; // 按字符(码点)数,中文名一字算一个

function urlOk(s, allowHttp) {
  if (typeof s !== 'string' || s.length > 2048) return false;
  try {
    const u = new URL(s);
    if (u.username || u.password) return false;
    return u.protocol === 'https:' || (allowHttp && u.protocol === 'http:');
  } catch { return false; }
}

/**
 * 纯函数:校验 manifest。
 * @returns {{ok:true, manifest:object} | {ok:false, reason:'bad_manifest', detail:string}}
 */
export function validateManifest(m, { allowPrivate = false, allowReserved = false } = {}) {
  const bad = (detail) => ({ ok: false, reason: 'bad_manifest', detail });
  if (!isObj(m)) return bad('not_object');
  let size;
  try { size = jsonSize(m); } catch { return bad('not_json'); }
  if (size > MANIFEST_MAX) return bad('too_large');
  for (const k of Object.keys(m)) if (!TOP_KEYS.has(k)) return bad(`unknown_field:${k}`);

  if (typeof m.id !== 'string' || m.id.length > 64 || !ID_RE.test(m.id)) return bad('id');
  if (!allowReserved && (m.id === 'lares' || m.id.startsWith('lares.'))) return bad('id_reserved');
  if (typeof m.name !== 'string' || !m.name.trim() || strLen(m.name) > 40) return bad('name');
  if (typeof m.version !== 'string' || m.version.length < 1 || m.version.length > 32 || !VERSION_RE.test(m.version)) return bad('version');
  if (m.description !== undefined && (typeof m.description !== 'string' || strLen(m.description) > 500)) return bad('description');
  if (typeof m.author !== 'string' || !m.author.trim() || strLen(m.author) > 80) return bad('author');
  if (m.homepage !== undefined && !urlOk(m.homepage, false)) return bad('homepage');
  if (m.entry !== undefined) {
    if (!isObj(m.entry)) return bad('entry');
    for (const k of Object.keys(m.entry)) if (k !== 'url') return bad(`unknown_field:entry.${k}`);
    if (!urlOk(m.entry.url, allowPrivate)) return bad('entry.url');
  }
  if (!Array.isArray(m.permissions)) return bad('permissions');
  if (m.permissions.length > 20) return bad('permissions');
  const perms = [];
  for (const p of m.permissions) {
    if (!PERMISSIONS.includes(p)) return bad(`unknown_permission:${String(p).slice(0, 40)}`);
    if (!perms.includes(p)) perms.push(p);
  }
  let webhook;
  if (m.webhook !== undefined) {
    if (!isObj(m.webhook)) return bad('webhook');
    for (const k of Object.keys(m.webhook)) if (k !== 'url' && k !== 'events') return bad(`unknown_field:webhook.${k}`);
    if (!urlOk(m.webhook.url, allowPrivate)) return bad('webhook.url');
    if (!Array.isArray(m.webhook.events) || m.webhook.events.length > 20) return bad('webhook.events');
    const events = [];
    for (const e of m.webhook.events) {
      if (!Object.prototype.hasOwnProperty.call(EVENT_PERMISSION, e)) return bad(`unknown_event:${String(e).slice(0, 40)}`);
      if (!perms.includes(EVENT_PERMISSION[e])) return bad(`event_needs_permission:${e}:${EVENT_PERMISSION[e]}`);
      if (!events.includes(e)) events.push(e);
    }
    webhook = { url: m.webhook.url, events };
  }
  if (m.settingsSchema !== undefined) {
    if (!isObj(m.settingsSchema)) return bad('settingsSchema');
    if (jsonSize(m.settingsSchema) > SETTINGS_SCHEMA_MAX) return bad('settingsSchema_too_large');
  }
  const out = {
    id: m.id,
    name: m.name.trim(),
    version: m.version,
    description: m.description ?? '',
    author: m.author.trim(),
    ...(m.homepage !== undefined ? { homepage: m.homepage } : {}),
    ...(m.entry !== undefined ? { entry: { url: m.entry.url } } : {}),
    permissions: perms,
    ...(webhook ? { webhook } : {}),
    ...(m.settingsSchema !== undefined ? { settingsSchema: m.settingsSchema } : {}),
  };
  return { ok: true, manifest: out };
}

/// RFC 7396 JSON Merge Patch。不改 target,返回新值。
export function mergePatch(target, patch) {
  if (!isObj(patch)) return patch;
  const out = isObj(target) ? { ...target } : {};
  for (const [k, v] of Object.entries(patch)) {
    if (v === null) delete out[k];
    else out[k] = mergePatch(out[k], v);
  }
  return out;
}

// ── 内置注册表 ───────────────────────────────────────────────────────────
export const BUILTINS = Object.freeze({
  [FOCUS_ID]: {
    manifest: Object.freeze({
      id: FOCUS_ID,
      name: '专注学习',
      version: '1.0.0',
      description: '一起专注:番茄钟、离开提醒、专注排行榜。启用后房间进入专注模式(专注段收起地图、语音便签与小程序,文字聊天照常)。',
      author: 'Lares',
      permissions: ['circle:read', 'members:read', 'state:read', 'focus:read'],
      settingsSchema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          focusMin: { type: 'integer', minimum: 1, maximum: 180, default: FOCUS_DEFAULTS.focusMin, title: '专注时长(分钟)' },
          breakMin: { type: 'integer', minimum: 1, maximum: 60, default: FOCUS_DEFAULTS.breakMin, title: '休息时长(分钟)' },
          rounds: { type: 'integer', minimum: 1, maximum: 12, default: FOCUS_DEFAULTS.rounds, title: '轮数' },
          graceSec: { type: 'integer', minimum: 0, maximum: 300, default: FOCUS_DEFAULTS.graceSec, title: '离开宽限(秒)' },
          membersCanStart: { type: 'boolean', default: FOCUS_DEFAULTS.membersCanStart, title: '成员可开番茄钟' },
        },
      },
    }),
    normalizeConfig: normalizeFocusConfig,
  },
  // lares.ai-voice:服务器托管的语音助手(进程监管在 ai_voice_supervisor.js)
  'lares.ai-voice': {
    manifest: Object.freeze({
      id: 'lares.ai-voice',
      name: 'AI 助手',
      version: '1.0.0',
      description: '房间里的语音 AI 助手:叫它的名字提问,它用语音回答。启用后,房间内正在说话成员的语音会发送到阿里云百炼(DashScope)做语音识别,回答由 DashScope 大模型生成并合成为语音。助手作为一名成员显示在房间里。服务端 E2EE 圈不可用(需由圈友带口令自行运行)。',
      author: 'Lares',
      permissions: ['circle:read', 'members:read', 'chat:read', 'chat:send', 'captions:send'],
      settingsSchema: AI_VOICE_SETTINGS_SCHEMA,
    }),
    normalizeConfig: normalizeAiVoiceConfig,
  },
});

/// PluginView:广播给成员的公开视图(不含 webhook URL / 密钥 / token)
export function pluginView(inst) {
  const m = inst.manifest;
  return {
    id: m.id,
    name: m.name,
    version: m.version,
    description: m.description ?? '',
    author: m.author,
    ...(m.homepage ? { homepage: m.homepage } : {}),
    ...(m.entry ? { entry: { url: m.entry.url } } : {}),
    permissions: [...m.permissions],
    builtin: inst.builtin === true,
    enabled: inst.enabled === true,
    config: inst.config ?? {},
    hasWebhook: Boolean(m.webhook),
    ...(m.settingsSchema ? { settingsSchema: m.settingsSchema } : {}),
    rev: inst.rev ?? 0,
  };
}

// ── 安装存储 ─────────────────────────────────────────────────────────────
export function createPluginStore({ dataDir }) {
  const file = path.join(dataDir, 'plugins.json');
  let circles = {};
  let writing = false;
  let dirty = false;
  let waiters = [];

  async function load() {
    try {
      const parsed = JSON.parse(await readFile(file, 'utf8'));
      circles = isObj(parsed?.circles) ? parsed.circles : {};
    } catch (e) {
      if (e?.code !== 'ENOENT') console.error('[plugin] plugins.json 读取失败:', e?.message ?? e);
      circles = {};
    }
  }

  async function kick() {
    if (writing) return;
    writing = true;
    try {
      while (dirty) {
        dirty = false;
        const batch = waiters;
        waiters = [];
        const data = JSON.stringify({ circles });
        try {
          await mkdir(dataDir, { recursive: true });
          const tmp = `${file}.${process.pid}.tmp`;
          await writeFile(tmp, data, { mode: 0o600 });
          await rename(tmp, file);
          for (const w of batch) w.res();
        } catch (e) {
          for (const w of batch) w.rej(e);
        }
      }
    } finally {
      writing = false;
    }
  }

  /// 合并写:连续多次 save 只落最后一份;每个调用者都拿到「包含自己改动」的那次写的结果
  function save() {
    return new Promise((res, rej) => {
      waiters.push({ res, rej });
      dirty = true;
      kick();
    });
  }

  function saveSync() {
    try {
      mkdirSync(dataDir, { recursive: true });
      const tmp = `${file}.${process.pid}.sync.tmp`;
      writeFileSync(tmp, JSON.stringify({ circles }), { mode: 0o600 });
      renameSync(tmp, file);
    } catch (e) { console.error('[plugin] 同步落盘失败:', e?.message ?? e); }
  }

  const of = (circleId) => (Object.prototype.hasOwnProperty.call(circles, circleId) ? circles[circleId] : null);
  const get = (circleId, pluginId) => {
    const c = of(circleId);
    return c && Object.prototype.hasOwnProperty.call(c, pluginId) ? c[pluginId] : null;
  };
  function put(circleId, pluginId, inst) {
    if (!of(circleId)) circles[circleId] = {};
    circles[circleId][pluginId] = inst;
  }
  function remove(circleId, pluginId) {
    const c = of(circleId);
    if (!c) return;
    delete c[pluginId];
    if (Object.keys(c).length === 0) delete circles[circleId];
  }
  function removeCircle(circleId) { delete circles[circleId]; }
  const list = (circleId) => Object.values(of(circleId) ?? {}).sort((a, b) => (a.installedAt ?? 0) - (b.installedAt ?? 0));
  const allCircleIds = () => Object.keys(circles);

  return { load, save, saveSync, get, put, remove, removeCircle, list, allCircleIds, file };
}

// ── 服务 + WS 处理 ───────────────────────────────────────────────────────
/**
 * @param {object} d
 *   store (createPluginStore), tokens (bot_tokens), webhooks (createWebhookDispatcher),
 *   botApi: {emit, closeToken}, send(ws,msg), sessionsOfCircle(id), lobbyConns() -> iterable ws,
 *   registeredCircle(id), ownerKeyOk(id,key), circleAllowed(session,id),
 *   broadcastLobbySummary(id), broadcastCircleSettings(id), env, fetchManifest?, resolveSafe?
 *   focus (set later via setFocus): {onPluginChanged(circleId, {installed, enabled, config, byOwner})}
 */
export function createPlugins(d) {
  const env = d.env ?? process.env;
  const allowPrivate = allowPrivateFrom(env);
  const doFetchManifest = d.fetchManifest ?? ((u) => fetchManifest(u, { allowPrivate }));
  const doResolve = d.resolveSafe ?? ((u) => resolveSafe(u, { allowPrivate }));
  const store = d.store;
  const adminRate = new TokenBuckets({ capacity: 20, perSec: 2 });
  const stateRate = new TokenBuckets({ capacity: 20, perSec: 5 });
  const readRate = new TokenBuckets({ capacity: 30, perSec: 5 });
  let focus = null;

  const cidOf = (msg) => (typeof msg.circleId === 'string' ? msg.circleId : '');
  const pidOf = (msg) => (typeof msg.pluginId === 'string' ? msg.pluginId : '');
  const connKey = (ws) => (ws._laresConnId ??= crypto.randomBytes(8).toString('hex'));

  const views = (circleId) => store.list(circleId).map(pluginView);
  const summary = (circleId) => store.list(circleId).map((i) => ({ id: i.manifest.id, enabled: i.enabled === true }));

  function isEnabled(circleId, pluginId) {
    return store.get(circleId, pluginId)?.enabled === true;
  }

  /// focus 引擎查询用
  function focusPlugin(circleId) {
    const inst = store.get(circleId, FOCUS_ID);
    if (!inst) return { installed: false, enabled: false, config: normalizeFocusConfig({}).config, state: {} };
    return { installed: true, enabled: inst.enabled === true, config: inst.config, state: inst.state ?? {} };
  }

  // ── 事件扇出 ──
  /// webhook 扇出:按订阅 + 权限 + 启用过滤。由 botApi.emit 的 onEmit 钩子调用(SSE 推一条,webhook 跟一条)。
  function fanout(circleId, type, data) {
    const perm = EVENT_PERMISSION[type];
    if (!perm) return;
    for (const inst of store.list(circleId)) {
      const m = inst.manifest;
      if (!m.webhook || !inst.enabled || !inst.webhookSecretEnc) continue;
      if (!inst.builtin && !featureOn(circleId, 'plugins')) continue; // 圈主关了第三方插件
      if (!m.webhook.events.includes(type) || !m.permissions.includes(perm)) continue;
      // 共享状态只推本插件自己的
      if (type === 'plugin_state' && data?.pluginId !== m.id) continue;
      d.webhooks.enqueue({ key: `${circleId}\0${m.id}`, url: m.webhook.url, secret: inst.webhookSecretEnc, type, circleId, pluginId: m.id, data });
    }
  }

  /// 生命周期事件:不需订阅,停用中也投
  function lifecycle(circleId, inst, type, data) {
    if (!inst?.manifest?.webhook || !inst.webhookSecretEnc) return;
    d.webhooks.enqueue({ key: `${circleId}\0${inst.manifest.id}`, url: inst.manifest.webhook.url, secret: inst.webhookSecretEnc, type, circleId, pluginId: inst.manifest.id, data });
  }

  function broadcastList(circleId) {
    const out = { t: 'plugins', circleId, items: views(circleId) };
    const seen = new Set();
    for (const ws of d.sessionsOfCircle(circleId)) { seen.add(ws); d.send(ws, out); }
    for (const ws of d.lobbyConns()) {
      if (seen.has(ws)) continue;
      const s = ws._laresSession;
      if (!s?.userId || !s.authed || !d.circleAllowed(s, circleId)) continue;
      d.send(ws, out);
    }
    d.botApi.emit(circleId, 'plugins', { circleId, items: out.items });
    d.broadcastLobbySummary(circleId);
    d.broadcastCircleSettings(circleId);
  }

  function notifyFocus(circleId, inst, byOwner = true) {
    if (!focus) return;
    focus.onPluginChanged(circleId, inst
      ? { installed: true, enabled: inst.enabled === true, config: inst.config, byOwner }
      : { installed: false, enabled: false, config: normalizeFocusConfig({}).config, byOwner });
  }

  /**
   * 合并共享状态。opts.server = 服务器自己写(专注番茄钟),跳过一切权限检查。
   * @returns {Promise<{ok:true, rev:number, state:object} | {ok:false, reason:string}>}
   */
  async function applyState(circleId, pluginId, patch) {
    const inst = store.get(circleId, pluginId);
    if (!inst) return { ok: false, reason: 'not_installed' };
    if (!isObj(patch)) return { ok: false, reason: 'bad_patch' };
    let psize;
    try { psize = jsonSize(patch); } catch { return { ok: false, reason: 'bad_patch' }; }
    if (psize > PATCH_MAX) return { ok: false, reason: 'too_large' };
    const next = mergePatch(inst.state ?? {}, patch);
    if (jsonSize(next) > STATE_MAX) return { ok: false, reason: 'too_large' };
    inst.state = next;
    inst.rev = (inst.rev ?? 0) + 1;
    store.save().catch((e) => console.error('[plugin] 共享状态写盘失败:', e?.message ?? e));
    const out = { t: 'plugin_state', circleId, pluginId, state: next, rev: inst.rev };
    for (const ws of d.sessionsOfCircle(circleId)) d.send(ws, out);
    d.botApi.emit(circleId, 'plugin_state', { circleId, pluginId, state: next, rev: inst.rev });
    return { ok: true, rev: inst.rev, state: next };
  }

  function ownerGate(ws, session, msg, op) {
    const circleId = cidOf(msg);
    const fail = (reason, detail) => { d.send(ws, { t: 'owner_error', op, circleId, reason, ...(detail ? { detail } : {}) }); return null; };
    if (!session.userId) return fail('say_hello_first');
    if (!d.registeredCircle(circleId)) return fail('not_registered');
    if (!d.ownerKeyOk(circleId, msg.ownerKey)) return fail('not_owner');
    if (adminRate.take(connKey(ws)) > 0) return fail('rate_limited');
    return { circleId, fail };
  }

  const isBuiltinId = (pid) => typeof pid === 'string' && Object.prototype.hasOwnProperty.call(BUILTINS, pid);
  const featureOn = (circleId, key) => (d.featureOn ? d.featureOn(circleId, key) !== false : true);

  /**
   * 把一个来源解析成已校验的 manifest(plugin_install 与用途共用同一条路径):
   * 内置 id / 内联 manifest / manifestUrl(抓取 + SSRF),带 webhook 的再解析地址。
   * @param {'pluginId'|'manifest'|'manifestUrl'} kind
   * @returns {Promise<{ok:true, manifest:object, builtin:boolean} | {ok:false, reason:string, detail?:string}>}
   */
  async function resolveSource(kind, value) {
    const no = (reason, detail) => ({ ok: false, reason, ...(detail ? { detail } : {}) });
    if (kind === 'pluginId') {
      if (!isBuiltinId(value)) return no('unknown_builtin');
      return { ok: true, manifest: JSON.parse(JSON.stringify(BUILTINS[value].manifest)), builtin: true };
    }
    let raw = value;
    if (kind === 'manifestUrl') {
      if (typeof value !== 'string') return no('bad_request');
      try {
        raw = await doFetchManifest(value);
      } catch (e) {
        const r = e?.reason === 'ssrf_blocked' ? 'ssrf_blocked'
          : e?.reason === 'bad_url' ? 'bad_request' : 'manifest_fetch_failed';
        return no(r, e?.detail ? String(e.detail).slice(0, 120) : undefined);
      }
    }
    const v = validateManifest(raw, { allowPrivate });
    if (!v.ok) return no(v.reason, v.detail);
    const manifest = v.manifest;
    if (manifest.webhook) {
      try {
        await doResolve(manifest.webhook.url);
      } catch (e) {
        if (e?.reason === 'bad_url') return no('bad_manifest', 'webhook.url');
        return no('ssrf_blocked', e?.detail ? String(e.detail).slice(0, 120) : undefined);
      }
    }
    return { ok: true, manifest, builtin: false };
  }

  function newInst(manifest, builtin, { enabled = true, config } = {}) {
    return {
      manifest,
      builtin,
      enabled,
      config: config ?? (builtin ? BUILTINS[manifest.id].normalizeConfig({}).config : {}),
      state: {},
      rev: 0,
      installedAt: Date.now(),
    };
  }

  async function install(ws, session, msg) {
    const g = ownerGate(ws, session, msg, 'plugin_install');
    if (!g) return;
    const { circleId, fail } = g;
    const sources = ['pluginId', 'manifest', 'manifestUrl'].filter((k) => msg[k] !== undefined && msg[k] !== null);
    if (sources.length !== 1) return fail('bad_request');
    // 圈主关了「第三方插件」:只许装内置
    if (sources[0] !== 'pluginId' && !featureOn(circleId, 'plugins')) return fail('feature_off');
    const src = await resolveSource(sources[0], sources[0] === 'pluginId' ? pidOf(msg) : msg[sources[0]]);
    if (!src.ok) return fail(src.reason, src.detail);
    const { manifest, builtin } = src;
    // await 之后再查重 / 计数,防并发装两次
    if (store.get(circleId, manifest.id)) return fail('already_installed');
    if (store.list(circleId).length >= PLUGINS_PER_CIRCLE_MAX) return fail('too_many');

    const inst = newInst(manifest, builtin);
    let token;
    let webhookSecret;
    if (manifest.webhook) {
      webhookSecret = newWebhookSecret();
      inst.webhookSecretEnc = webhookSecret;
      try {
        const r = await d.tokens.create(circleId, manifest.name, { kind: 'plugin', pluginId: manifest.id });
        token = r.token;
        inst.tokenId = r.record.id;
      } catch (e) {
        console.error('[plugin] 签发插件 token 失败:', e?.message ?? e);
        return fail('save_failed');
      }
    }
    if (store.get(circleId, manifest.id)) { // token 签发期间别人装上了
      if (inst.tokenId) await d.tokens.revokeById(inst.tokenId).catch(() => {});
      return fail('already_installed');
    }
    store.put(circleId, manifest.id, inst);
    try {
      await store.save();
    } catch (e) {
      store.remove(circleId, manifest.id);
      if (inst.tokenId) await d.tokens.revokeById(inst.tokenId).catch(() => {});
      console.error('[plugin] 安装写盘失败:', e?.message ?? e);
      return fail('save_failed');
    }
    d.send(ws, {
      t: 'plugin_installed', circleId, plugin: pluginView(inst),
      ...(token ? { token } : {}), ...(webhookSecret ? { webhookSecret } : {}),
    });
    if (token) lifecycle(circleId, inst, 'installed', { token });
    broadcastList(circleId);
    if (manifest.id === FOCUS_ID) notifyFocus(circleId, inst);
  }

  async function uninstall(ws, session, msg) {
    const g = ownerGate(ws, session, msg, 'plugin_uninstall');
    if (!g) return;
    const pid = pidOf(msg);
    const inst = store.get(g.circleId, pid);
    if (!inst) return g.fail('not_found');
    store.remove(g.circleId, pid);
    try {
      await store.save();
    } catch (e) {
      store.put(g.circleId, pid, inst);
      console.error('[plugin] 卸载写盘失败:', e?.message ?? e);
      return g.fail('save_failed');
    }
    lifecycle(g.circleId, inst, 'uninstalled', {}); // 密钥随 job 带走,删记录后照样能投
    if (inst.tokenId) {
      try { await d.tokens.revokeById(inst.tokenId); } catch (e) { console.error('[plugin] 吊销插件 token 失败:', e?.message ?? e); }
      d.botApi.closeToken(inst.tokenId);
    }
    d.send(ws, { t: 'owner_ok', op: 'plugin_uninstall', circleId: g.circleId, pluginId: pid });
    broadcastList(g.circleId);
    if (pid === FOCUS_ID) notifyFocus(g.circleId, null);
  }

  async function setEnabled(ws, session, msg) {
    const g = ownerGate(ws, session, msg, 'plugin_set_enabled');
    if (!g) return;
    if (typeof msg.enabled !== 'boolean') return g.fail('bad_request');
    const pid = pidOf(msg);
    const inst = store.get(g.circleId, pid);
    if (!inst) return g.fail('not_found');
    const prev = inst.enabled;
    inst.enabled = msg.enabled;
    try {
      await store.save();
    } catch (e) {
      inst.enabled = prev;
      console.error('[plugin] 启停写盘失败:', e?.message ?? e);
      return g.fail('save_failed');
    }
    d.send(ws, { t: 'owner_ok', op: 'plugin_set_enabled', circleId: g.circleId, pluginId: pid });
    if (prev !== inst.enabled) {
      lifecycle(g.circleId, inst, 'enabled', { enabled: inst.enabled });
      // 停用:正在连着的 SSE 立刻关(新请求会拿到 403 plugin_disabled)
      if (!inst.enabled && inst.tokenId) d.botApi.closeToken(inst.tokenId);
      broadcastList(g.circleId);
      if (pid === FOCUS_ID) notifyFocus(g.circleId, inst);
    }
  }

  async function configSet(ws, session, msg) {
    const g = ownerGate(ws, session, msg, 'plugin_config_set');
    if (!g) return;
    const pid = pidOf(msg);
    const inst = store.get(g.circleId, pid);
    if (!inst) return g.fail('not_found');
    if (!isObj(msg.config)) return g.fail('bad_config');
    let size;
    try { size = jsonSize(msg.config); } catch { return g.fail('bad_config'); }
    if (size > CONFIG_MAX) return g.fail('bad_config', 'too_large');
    let config = msg.config;
    if (inst.builtin && BUILTINS[pid]?.normalizeConfig) {
      const r = BUILTINS[pid].normalizeConfig(msg.config);
      if (!r.ok) return g.fail('bad_config', r.detail);
      config = r.config;
    }
    const prev = inst.config;
    inst.config = config;
    try {
      await store.save();
    } catch (e) {
      inst.config = prev;
      console.error('[plugin] 配置写盘失败:', e?.message ?? e);
      return g.fail('save_failed');
    }
    d.send(ws, { t: 'owner_ok', op: 'plugin_config_set', circleId: g.circleId, pluginId: pid });
    lifecycle(g.circleId, inst, 'config', { config });
    broadcastList(g.circleId);
    if (pid === FOCUS_ID) notifyFocus(g.circleId, inst);
  }

  // ── 用途 / 功能开关用的批量接口(features.js 调;契约 features-purpose-contract §2 §3.3)──
  // 流程:plan(全部校验 + 抓取,不动存储)→ issueTokens → commit(内存改,返回快照)
  //      → 调用方 await savePlugins() 与圈设置落盘 → 成功 announce / 失败 restore + revokeTokens。

  /**
   * @param {Array<{id?:string, manifest?:object, manifestUrl?:string, enabled:boolean, config?:object}>} items
   *   已经过 validatePurpose 结构校验的插件项
   * @returns {Promise<{ok:true, plan:Array} | {ok:false, reason:string, detail?:string}>}
   */
  async function planPurposePlugins(circleId, items, { allowThirdParty = true } = {}) {
    const plan = [];
    const seen = new Set();
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      const at = `plugins[${i}]`;
      const no = (reason, detail) => ({ ok: false, reason, detail: detail ? `${at}:${detail}` : at });
      let manifest;
      let builtin;
      if (it.id !== undefined) {
        const existing = store.get(circleId, it.id);
        if (existing) { manifest = existing.manifest; builtin = existing.builtin === true; }
        else if (isBuiltinId(it.id)) { manifest = JSON.parse(JSON.stringify(BUILTINS[it.id].manifest)); builtin = true; }
        else return no('unknown_builtin', it.id.slice(0, 64));
      } else {
        const kind = it.manifest !== undefined ? 'manifest' : 'manifestUrl';
        const src = await resolveSource(kind, it[kind]);
        if (!src.ok) return no(src.reason, src.detail);
        manifest = src.manifest;
        builtin = false;
      }
      const pid = manifest.id;
      if (seen.has(pid)) return no('bad_purpose', 'duplicate');
      seen.add(pid);
      const existing = store.get(circleId, pid);
      if (!existing && !builtin && !allowThirdParty) return no('feature_off');
      let config;
      if (builtin && BUILTINS[pid]?.normalizeConfig) {
        const base = it.config ?? (existing ? existing.config : {});
        const r = BUILTINS[pid].normalizeConfig(base ?? {});
        if (!r.ok) return no('bad_purpose', `config:${r.detail}`);
        config = r.config;
      } else {
        config = it.config ?? (existing ? existing.config : {});
      }
      plan.push({ pluginId: pid, action: existing ? 'update' : 'install', manifest: existing ? existing.manifest : manifest, builtin, enabled: it.enabled !== false, config });
    }
    const installs = plan.filter((p) => p.action === 'install').length;
    if (store.list(circleId).length + installs > PLUGINS_PER_CIRCLE_MAX) return { ok: false, reason: 'too_many', detail: 'plugins' };
    return { ok: true, plan };
  }

  /// 给计划里新装且带 webhook 的插件签 token + 生成密钥(写在 plan 项上)。失败自己吊销已签的再抛。
  async function issueTokens(circleId, plan) {
    const issued = [];
    try {
      for (const p of plan) {
        if (p.action !== 'install' || !p.manifest.webhook) continue;
        p.webhookSecret = newWebhookSecret();
        const r = await d.tokens.create(circleId, p.manifest.name, { kind: 'plugin', pluginId: p.pluginId });
        p.token = r.token;
        p.tokenId = r.record.id;
        issued.push(r.record.id);
      }
    } catch (e) {
      await revokeTokens(plan);
      throw e;
    }
  }

  async function revokeTokens(plan) {
    for (const p of plan) {
      if (!p.tokenId) continue;
      await d.tokens.revokeById(p.tokenId).catch(() => {});
      d.botApi.closeToken(p.tokenId);
      delete p.tokenId; delete p.token;
    }
  }

  /// 同步改内存。返回快照(原实例引用或 null),给 restore / announce 用。
  /// 并发装上了同 id(token 签发期间)→ 返回 {ok:false} 什么都不改。
  function commitPlan(circleId, plan) {
    for (const p of plan) {
      if (p.action === 'install' && store.get(circleId, p.pluginId)) return { ok: false, reason: 'already_installed', detail: p.pluginId };
      if (p.action === 'update' && !store.get(circleId, p.pluginId)) return { ok: false, reason: 'not_found', detail: p.pluginId };
    }
    if (store.list(circleId).length + plan.filter((p) => p.action === 'install').length > PLUGINS_PER_CIRCLE_MAX) {
      return { ok: false, reason: 'too_many', detail: 'plugins' };
    }
    // 快照只记「改了的字段」:更新是就地改实例(共享状态的并发写不会被回滚冲掉)
    const snap = new Map();
    for (const p of plan) {
      const cur = store.get(circleId, p.pluginId);
      if (p.action === 'install') {
        snap.set(p.pluginId, null);
        const inst = newInst(p.manifest, p.builtin, { enabled: p.enabled, config: p.config });
        if (p.webhookSecret) inst.webhookSecretEnc = p.webhookSecret;
        if (p.tokenId) inst.tokenId = p.tokenId;
        store.put(circleId, p.pluginId, inst);
      } else {
        snap.set(p.pluginId, { enabled: cur.enabled === true, config: cur.config });
        cur.enabled = p.enabled;
        cur.config = p.config;
      }
    }
    return { ok: true, snap };
  }

  function restore(circleId, snap) {
    for (const [pid, prev] of snap) {
      if (!prev) { store.remove(circleId, pid); continue; }
      const cur = store.get(circleId, pid);
      if (cur) { cur.enabled = prev.enabled; cur.config = prev.config; }
    }
  }

  /// 落盘成功后:生命周期 webhook + 停用关 SSE + 专注引擎 + 插件列表广播(含摘要与圈设置)
  function announce(circleId, plan, snap, { broadcast = true } = {}) {
    let changed = false;
    for (const p of plan) {
      const inst = store.get(circleId, p.pluginId);
      if (!inst) continue;
      const prev = snap.get(p.pluginId);
      if (!prev) {
        changed = true;
        if (p.token) lifecycle(circleId, inst, 'installed', { token: p.token });
      } else {
        if (prev.enabled !== inst.enabled) {
          changed = true;
          lifecycle(circleId, inst, 'enabled', { enabled: inst.enabled });
          if (!inst.enabled && inst.tokenId) d.botApi.closeToken(inst.tokenId);
        }
        if (JSON.stringify(prev.config ?? {}) !== JSON.stringify(inst.config ?? {})) {
          changed = true;
          lifecycle(circleId, inst, 'config', { config: inst.config });
        }
      }
      if (p.pluginId === FOCUS_ID && (!prev || prev.enabled !== inst.enabled || JSON.stringify(prev.config) !== JSON.stringify(inst.config))) {
        notifyFocus(circleId, inst);
      }
    }
    if (changed && broadcast) broadcastList(circleId);
    return changed;
  }

  /// 导出用:所有已装插件(内置给 id,第三方给完整 manifest,含 webhook 地址)
  function exportItems(circleId) {
    return store.list(circleId).map((inst) => ({
      ...(inst.builtin ? { id: inst.manifest.id } : { manifest: JSON.parse(JSON.stringify(inst.manifest)) }),
      enabled: inst.enabled === true,
      config: JSON.parse(JSON.stringify(inst.config ?? {})),
    }));
  }

  async function handle(ws, session, msg) {
    switch (msg.t) {
      case 'plugin_install': await install(ws, session, msg); return true;
      case 'plugin_uninstall': await uninstall(ws, session, msg); return true;
      case 'plugin_set_enabled': await setEnabled(ws, session, msg); return true;
      case 'plugin_config_set': await configSet(ws, session, msg); return true;

      case 'plugin_list':
      case 'plugin_state_get': {
        const circleId = cidOf(msg);
        const op = msg.t;
        const fail = (reason) => { d.send(ws, { t: 'plugin_error', op, circleId, ...(op === 'plugin_state_get' ? { pluginId: pidOf(msg) } : {}), reason }); return true; };
        if (!session.userId || !session.authed) return fail('say_hello_first');
        if (!circleId || !d.circleAllowed(session, circleId)) return fail('auth_scope');
        if (readRate.take(connKey(ws)) > 0) return fail('rate_limited');
        if (op === 'plugin_list') {
          d.send(ws, { t: 'plugins', circleId, items: views(circleId) });
          return true;
        }
        const inst = store.get(circleId, pidOf(msg));
        if (!inst) return fail('not_installed');
        d.send(ws, { t: 'plugin_state', circleId, pluginId: inst.manifest.id, state: inst.state ?? {}, rev: inst.rev ?? 0 });
        return true;
      }

      case 'plugin_state_set': {
        const circleId = cidOf(msg);
        const pluginId = pidOf(msg);
        const fail = (reason) => { d.send(ws, { t: 'plugin_error', op: 'plugin_state_set', circleId, pluginId, reason }); return true; };
        if (!session.userId || !session.authed || !circleId || session.circleId !== circleId) return fail('not_in_room');
        const inst = store.get(circleId, pluginId);
        if (!inst) return fail('not_installed');
        if (!inst.enabled) return fail('disabled');
        if (pluginId === FOCUS_ID || inst.builtin || !inst.manifest.permissions.includes('state:write')) return fail('forbidden');
        if (stateRate.take(session.userId) > 0) return fail('rate_limited');
        const r = await applyState(circleId, pluginId, msg.patch);
        if (!r.ok) return fail(r.reason);
        return true;
      }
    }
    return false;
  }

  /// 插件 token 查自己的安装(bot_api 鉴权用)
  function installOf(circleId, pluginId) {
    return store.get(circleId, pluginId);
  }

  async function onCircleDeleted(circleId) {
    for (const inst of store.list(circleId)) d.webhooks.drop(`${circleId}\0${inst.manifest.id}`);
    if (!store.list(circleId).length) return;
    store.removeCircle(circleId);
    try { await store.save(); } catch (e) { console.error('[plugin] 解散清理写盘失败:', e?.message ?? e); }
  }

  function sweep() { adminRate.sweep(); stateRate.sweep(); readRate.sweep(); }

  return {
    handle, views, summary, isEnabled, installOf, focusPlugin, applyState, fanout, onCircleDeleted, sweep,
    // 用途 / 功能开关(features.js)
    planPurposePlugins, issueTokens, revokeTokens, commitPlan, restore, announce, exportItems,
    savePlugins: () => store.save(),
    setFocus: (f) => { focus = f; },
    flushSync: () => store.saveSync(),
  };
}
