// 输出通道 · 本地消息流:feed.jsonl(追加,保留最近 500 条),托盘「最近消息」与 /ui 读取。
// 永远运行(daemon 的 notify 直接写它);stop 只是不再接收 broadcast。
import { appendFileSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { files } from '../paths.mjs';

export const RING = 500;

export function readFeed(file, n = 20) {
  if (!existsSync(file)) return [];
  const lines = readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean);
  const out = [];
  for (const l of lines.slice(-Math.max(1, Math.min(n, RING)))) { try { out.push(JSON.parse(l)); } catch { /* */ } }
  return out;
}

export default function outputFeed(ctx) {
  const file = files(ctx.stateDir).feed;
  let count = null;
  let running = true;
  const trim = () => {
    const lines = readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean);
    if (lines.length > RING) writeFileSync(file, `${lines.slice(-RING).join('\n')}\n`);
    count = Math.min(lines.length, RING);
  };
  const ch = {
    id: 'feed',
    kind: 'output',
    name: '消息流',
    describe: () => '本地消息流(feed.jsonl),托盘「最近消息」与状态页显示',
    configured: () => true,
    async start() { running = true; },
    async stop() { running = false; },
    status: () => ({ running, detail: running ? '运行中' : '已停(仍记录会议事件)' }),
    /// 写一条(无论是否 running;会议事件必须留痕)。返回规范化后的条目
    append(item) {
      const it = { at: item.at ?? new Date().toISOString(), kind: String(item.kind ?? 'info'), title: String(item.title ?? ''), text: String(item.text ?? '') };
      appendFileSync(file, `${JSON.stringify(it)}\n`);
      if (count === null) { try { count = readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean).length; } catch { count = 0; } } else count++;
      if (count > RING + 50) trim();
      return it;
    },
    read: (n) => readFeed(file, n),
    async send() { return true; }, // 由 daemon.notify 直接 append,这里不重复写
  };
  return ch;
}
