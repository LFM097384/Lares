// 灶语 · 可选 npm 依赖解析。本体唯一的 npm 依赖是 `ws`(DashScope 实时 ASR / TTS 用),而且可以注入
// (DashscopeAsr / DashscopeTts 的 o.WebSocket),所以这里找不到也不报错,只返回 null。
//
// 查找顺序:
//  1. 常规裸 import(装在本包或任意上级 node_modules 里;镜像里 /app/node_modules 就命中);
//  2. 本仓库约定:与本包同级的 server/ 的 node_modules(开发机上仓库根没有 node_modules)。
//     这只是单仓库的便利退路,不是对 Lares 的依赖:目录不存在时直接跳过。

import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ANCHORS = [path.join(HERE, '..', 'server', 'package.json')];

/// import 一个裸包;都找不到返回 null。
export async function importOptional(name) {
  try { return await import(name); } catch { /* 退路 */ }
  for (const anchor of ANCHORS) {
    try { return await import(pathToFileURL(createRequire(anchor).resolve(name)).href); } catch { /* 下一个 */ }
  }
  return null;
}
