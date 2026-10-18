// 测试专用:readReleasedKnowledge 的替身(LARES_ANONYM_FILEMEMORY_MODULE)。
// 读 <dir>/released.json(数组);q 非空时按子串过滤。记录被调用的 dir,供测试核对路径。
import { readFileSync, appendFileSync } from 'node:fs';
import path from 'node:path';

export async function readReleasedKnowledge(dir, q) {
  appendFileSync(path.join(dir, 'calls.log'), JSON.stringify({ dir, q }) + '\n');
  let items = [];
  try { items = JSON.parse(readFileSync(path.join(dir, 'released.json'), 'utf8')); } catch { return []; }
  return q ? items.filter((x) => String(x.text).includes(q)) : items;
}
