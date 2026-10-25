// ember-desk · 配置(非机密,config.json)、token(bearer)、机密(env 优先,否则 DPAPI 解密 secrets.dpapi.json)。
// 机密值绝不写日志、不写文件、不进 feed;只注入会议插件子进程的 env。
import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import path from 'node:path';
import { files, HERE } from './paths.mjs';

export const DEFAULT_CONFIG = Object.freeze({
  jitsiHosts: ['localhost:8443'],
  defaultK: null,
  convenerName: null,
  enabledChannels: ['feed', 'toast'],
  asr: 'dashscope',
  micDevice: null,
});

export const SECRET_KEYS = Object.freeze(['LARES_AI_LLM_KEY', 'LARES_AI_LLM_BASE_URL', 'LARES_AI_LLM_MODEL', 'LARES_DASHSCOPE_API_KEY', 'ZOOM_CLIENT_ID', 'ZOOM_CLIENT_SECRET', 'ZOOM_WEBHOOK_SECRET']);
const ALIASES = Object.freeze({ LARES_AI_LLM_API_KEY: 'LARES_AI_LLM_KEY' });

export function ensureDir(dir) { mkdirSync(dir, { recursive: true }); return dir; }

/// 原子写:先写 .tmp 再 rename
export function writeJsonAtomic(file, obj) {
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(obj, null, 2)}\n`);
  renameSync(tmp, file);
}

export function readJson(file, fallback = null) {
  try { return JSON.parse(readFileSync(file, 'utf8').replace(/^\uFEFF/, '')); } catch { return fallback; }
}

export function normalizeConfig(raw) {
  const c = { ...DEFAULT_CONFIG, ...(raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {}) };
  c.jitsiHosts = Array.isArray(c.jitsiHosts) ? c.jitsiHosts.map((h) => String(h).trim().toLowerCase()).filter(Boolean) : [...DEFAULT_CONFIG.jitsiHosts];
  c.enabledChannels = Array.isArray(c.enabledChannels) ? [...new Set(c.enabledChannels.map(String))] : [...DEFAULT_CONFIG.enabledChannels];
  if (c.defaultK !== null && !(Number.isInteger(c.defaultK) && c.defaultK >= 1 && c.defaultK <= 20)) c.defaultK = null;
  if (!['dashscope', 'mock', 'none'].includes(c.asr)) c.asr = 'dashscope';
  if (c.convenerName !== null) c.convenerName = String(c.convenerName).slice(0, 64) || null;
  if (c.micDevice !== null) c.micDevice = String(c.micDevice) || null;
  return c;
}

/// 读 config.json;缺失则写默认值(write=true 时)
export function loadConfig(dir, { write = true } = {}) {
  const f = files(dir).config;
  const raw = readJson(f, null);
  const c = normalizeConfig(raw);
  if (write && raw === null) { ensureDir(dir); writeJsonAtomic(f, c); }
  return c;
}

export function saveConfig(dir, cfg) { ensureDir(dir); writeJsonAtomic(files(dir).config, normalizeConfig(cfg)); }

/// best-effort:把文件 ACL 收紧到当前用户(去继承,只给 %USERNAME% 完全控制)
export function restrictToUser(file, { platform = process.platform, run = spawnSync, env = process.env } = {}) {
  if (platform !== 'win32') return false;
  const user = String(env.USERNAME ?? '').trim();
  if (!user) return false;
  try {
    const r = run('icacls', [file, '/inheritance:r', '/grant:r', `${user}:F`], { windowsHide: true, stdio: 'ignore', timeout: 10_000 });
    return r?.status === 0;
  } catch { return false; }
}

export function readToken(dir) {
  try { const t = readFileSync(files(dir).token, 'utf8').trim(); return /^[0-9a-f]{64}$/.test(t) ? t : null; } catch { return null; }
}

/// token 不存在则生成(32 字节随机 → 64 hex),独占创建,ACL 收紧
export function ensureToken(dir, opts = {}) {
  const have = readToken(dir);
  if (have) return have;
  ensureDir(dir);
  const t = randomBytes(32).toString('hex');
  const f = files(dir).token;
  try { writeFileSync(f, t, { flag: 'wx' }); } catch { writeFileSync(f, t); }
  restrictToUser(f, opts);
  return readToken(dir) ?? t;
}

/// 解密脚本:路径经 env 传入,绝不拼接进命令;输出单行 JSON {key:plain}
const DECRYPT_PS = [
  '$ErrorActionPreference = "Stop"',
  '$o = @{}',
  '$j = Get-Content -LiteralPath $env:EMBER_DESK_SECRETS_FILE -Raw -Encoding utf8 | ConvertFrom-Json',
  'foreach ($p in $j.PSObject.Properties) { try { $s = ConvertTo-SecureString -String ([string]$p.Value); $o[$p.Name] = [Net.NetworkCredential]::new("", $s).Password } catch { } }',
  '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)',
  '[Console]::Out.Write(($o | ConvertTo-Json -Compress))',
].join('; ');

/// 优先用 PowerShell 侧的 read-secrets.ps1(-File,路径作参数);不存在时退回内联脚本(路径经 env 传入)
export const READ_SECRETS_PS1 = path.join(HERE, 'read-secrets.ps1');

export function decryptSecretsFile(file, { spawnImpl = spawn, shell = 'pwsh', timeoutMs = 20_000, script = READ_SECRETS_PS1 } = {}) {
  return new Promise((resolve) => {
    if (!existsSync(file)) return resolve({});
    let out = '';
    let child;
    try {
      const args = existsSync(script) ? ['-NoProfile', '-NonInteractive', '-File', script, '-Path', file] : ['-NoProfile', '-NonInteractive', '-Command', DECRYPT_PS];
      child = spawnImpl(shell, args, {
        windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'], env: { ...process.env, EMBER_DESK_SECRETS_FILE: file },
      });
    } catch { return resolve({}); }
    const t = setTimeout(() => { try { child.kill(); } catch { /* */ } }, timeoutMs);
    child.stdout.on('data', (d) => { out += d; });
    child.on('error', () => { clearTimeout(t); resolve({}); });
    child.on('close', () => {
      clearTimeout(t);
      try { const o = JSON.parse(out.trim() || '{}'); resolve(o && typeof o === 'object' ? o : {}); } catch { resolve({}); }
    });
  });
}

/// env 优先,其次 DPAPI 文件。返回 {KEY: value}(只含有值的键);source 记录来源(不含值)
export async function loadSecrets(dir, { env = process.env, decrypt = decryptSecretsFile } = {}) {
  const out = {};
  const source = {};
  const fromEnv = (k) => String(env[k] ?? '').trim();
  for (const k of SECRET_KEYS) { const v = fromEnv(k); if (v) { out[k] = v; source[k] = 'env'; } }
  for (const [alias, k] of Object.entries(ALIASES)) { const v = fromEnv(alias); if (v && !out[k]) { out[k] = v; source[k] = 'env'; } }
  const missing = SECRET_KEYS.filter((k) => !out[k]);
  if (missing.length) {
    const f = files(dir).secrets;
    if (existsSync(f)) {
      const dec = await decrypt(f);
      for (const [rawK, v] of Object.entries(dec ?? {})) {
        const k = ALIASES[rawK] ?? rawK;
        if (SECRET_KEYS.includes(k) && !out[k] && String(v ?? '').trim()) { out[k] = String(v).trim(); source[k] = 'dpapi'; }
      }
    }
  }
  Object.defineProperty(out, '__source', { value: source, enumerable: false });
  return out;
}

/// 注入子进程 env:LLM key 两个名字都给(ember-jitsi 认 LARES_AI_LLM_API_KEY 或 LARES_AI_LLM_KEY)
export function childEnv(secrets, base = process.env, extra = {}) {
  const e = { ...base };
  for (const k of SECRET_KEYS) if (secrets?.[k]) e[k] = secrets[k];
  if (secrets?.LARES_AI_LLM_KEY) e.LARES_AI_LLM_API_KEY = secrets.LARES_AI_LLM_KEY;
  return { ...e, ...extra };
}

/// 只给出「有没有」,用于状态显示
export function secretPresence(secrets) {
  const o = {};
  for (const k of SECRET_KEYS) o[k] = Boolean(secrets?.[k]);
  return o;
}
