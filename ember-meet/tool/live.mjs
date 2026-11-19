#!/usr/bin/env node
// ember-meet · 真会冒烟:一条命令同时拉起炉灵(index.mjs)和模拟说话人「测试用户」(sim/speaker.mjs),进同一个会。
//   node ember-meet/tool/live.mjs --url "<Teams 会议链接>" [--headless] [--minutes 10] [--no-speaker]
// 两个子进程的 stdout 元数据事件加前缀打印到本终端;Ctrl+C → 两个都离会。见 LIVE-TEST.md。
import { spawn } from 'node:child_process';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const get = (k) => (argv.includes(k) ? argv[argv.indexOf(k) + 1] : undefined);
const url = get('--url');
if (!url) { process.stderr.write('usage: node ember-meet/tool/live.mjs --url "<Teams meeting link>" [--headless] [--minutes 10] [--no-speaker]\n'); process.exit(2); }
const headless = argv.includes('--headless');
const minutes = Number(get('--minutes') ?? 15);

const kids = [];
function run(tag, script, args) {
  const c = spawn(process.execPath, [script, ...args], { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
  const pre = (s) => `${new Date().toISOString().slice(11, 19)} ${tag} ${s}`;
  readline.createInterface({ input: c.stdout }).on('line', (l) => process.stdout.write(`${pre(l)}\n`));
  readline.createInterface({ input: c.stderr }).on('line', (l) => process.stderr.write(`${pre(l)}\n`));
  c.on('exit', (code) => process.stdout.write(`${pre(`exited code=${code}`)}\n`));
  c.stdin.on('error', () => {});
  kids.push(c);
  return c;
}

const mode = headless ? ['--headless'] : ['--headed'];
const bot = run('[炉灵]', path.join(HERE, '..', 'index.mjs'), ['--url', url, ...mode]);
// 说话人晚几秒进,让组织者先放行炉灵(大厅里两个人的顺序更好认)
const spk = argv.includes('--no-speaker') ? null : setTimeout(() => run('[测试用户]', path.join(HERE, '..', 'sim', 'speaker.mjs'), ['--url', url, '--minutes', String(minutes), ...mode]), 8000);

let stopping = false;
function stop() {
  if (stopping) return;
  stopping = true;
  clearTimeout(spk);
  for (const c of kids) { try { c.stdin.write('{"cmd":"stop"}\n'); } catch { /* */ } }
  setTimeout(() => { for (const c of kids) if (c.exitCode === null) c.kill(); process.exit(0); }, 15_000).unref();
}
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
setTimeout(stop, (minutes + 1) * 60_000).unref();
bot.on('exit', () => { if (!stopping) stop(); });
