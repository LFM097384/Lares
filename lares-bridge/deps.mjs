// lares-bridge · npm 依赖解析(ws / hash-wasm / 可选 @livekit/rtc-node)。
//
// 这些包不单独安装,只认 server/ 那一份 node_modules:
//  - 镜像:/app/node_modules → /app/server/node_modules(server/Dockerfile 的软链),裸 import 直接命中;
//  - 开发机:仓库根没有 node_modules,裸 import 找不到 → 退回按 ../server/package.json(再 ../server/tool/package.json)解析。
// 包本身放在仓库根、与 server/ 同级(镜像同布局),所以这里的相对路径在两边一致。

import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
/// 退回解析的锚点:server/(主依赖)→ server/tool/(验证工具单独装的 rtc-node)
export const FALLBACK_ANCHORS = Object.freeze([
  path.join(HERE, '..', 'server', 'package.json'),
  path.join(HERE, '..', 'server', 'tool', 'package.json'),
]);

/// import 一个裸包:先常规解析,失败再按 FALLBACK_ANCHORS 依次试。都不行抛最后一个错误。
export async function importDep(name) {
  let last;
  try { return await import(name); } catch (e) { last = e; }
  for (const anchor of FALLBACK_ANCHORS) {
    try {
      const req = createRequire(anchor);
      return await import(pathToFileURL(req.resolve(name)).href);
    } catch (e) { last = e; }
  }
  throw last;
}

const wsMod = await importDep('ws');
const hashMod = await importDep('hash-wasm');

export const WebSocket = wsMod.WebSocket ?? wsMod.default;
export const argon2id = hashMod.argon2id ?? hashMod.default?.argon2id;
if (typeof WebSocket !== 'function' || typeof argon2id !== 'function') throw new Error('lares-bridge: ws / hash-wasm unavailable (expected under server/node_modules)');
