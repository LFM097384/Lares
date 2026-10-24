// ember-zoom · 唯一的 npm 依赖 ws。与 lares-bridge/deps.mjs 同法解析:
//  - 先裸 import(镜像里 /app/node_modules → server/node_modules 的软链直接命中);
//  - 开发机仓库根没有 node_modules → 退回按 ../server/package.json 解析 server/node_modules/ws。
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const FALLBACK_ANCHORS = Object.freeze([path.join(HERE, '..', 'server', 'package.json')]);

export async function importDep(name) {
  let last;
  try { return await import(name); } catch (e) { last = e; }
  for (const anchor of FALLBACK_ANCHORS) {
    try { return await import(pathToFileURL(createRequire(anchor).resolve(name)).href); } catch (e) { last = e; }
  }
  throw last;
}

const wsMod = await importDep('ws');
export const WebSocket = wsMod.WebSocket ?? wsMod.default;
export const WebSocketServer = wsMod.WebSocketServer ?? wsMod.default?.Server ?? wsMod.Server;
if (typeof WebSocket !== 'function' || typeof WebSocketServer !== 'function') throw new Error('ember-zoom: ws unavailable (expected under server/node_modules)');
