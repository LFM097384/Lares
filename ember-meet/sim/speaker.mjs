#!/usr/bin/env node
// ember-meet · 模拟的第二位参会者「测试用户」:另一个 Chromium 以访客身份进同一个会,麦克风 = 一段离线生成的 WAV(循环播放)。
// 用来在真 Teams 会议里产生实时字幕,检验炉灵的字幕 → 账本链路。不开摄像头,不读字幕,不发聊天(除非 --say)。
//   node ember-meet/sim/speaker.mjs --url <会议链接> [--wav .data/ember-meet/speaker.wav] [--name 测试用户] [--headless] [--minutes 10] [--say "@炉灵 同意"]
// 没有 --wav 时先调 sim/make-wav.ps1(Windows SAPI,离线)生成到 .data/ember-meet/speaker.wav;非 Windows 下需要事先给 --wav。
// stdout:一行一个 JSON 元数据事件(state / ready / error / exit)。stdin {"cmd":"stop"} 或 SIGINT → 离会。
import { existsSync } from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createDriver } from '../driver.mjs';
import { resolveMeeting, REPO } from '../index.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const out = (ev) => process.stdout.write(`${JSON.stringify(ev)}\n`);
const log = (m) => process.stderr.write(`[sim-speaker] ${m}\n`);

function parse(argv) {
  const o = { name: '测试用户', minutes: 30, headless: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const v = () => argv[++i];
    if (a === '--url') o.url = v();
    else if (a === '--wav') o.wav = v();
    else if (a === '--name') o.name = v();
    else if (a === '--minutes') o.minutes = Number(v());
    else if (a === '--say') o.say = v();
    else if (a === '--headless') o.headless = true;
    else if (a === '--headed') o.headless = false;
    else throw new Error(`unknown argument ${a}`);
  }
  if (!o.url) throw new Error('--url is required');
  return o;
}

export function ensureWav(wav) {
  const target = wav ?? path.join(REPO, '.data', 'ember-meet', 'speaker.wav');
  if (existsSync(target)) return target;
  if (wav) throw new Error(`WAV not found: ${wav}`);
  if (process.platform !== 'win32') throw new Error('no WAV: generate it on Windows with ember-meet/sim/make-wav.ps1, or pass --wav');
  const r = spawnSync('pwsh', ['-NoProfile', '-File', path.join(HERE, 'make-wav.ps1'), '-Out', target], { stdio: ['ignore', 'pipe', 'inherit'], encoding: 'utf8' });
  if (r.status !== 0 || !existsSync(target)) throw new Error('make-wav.ps1 failed');
  return target;
}

async function main() {
  let o;
  try { o = parse(process.argv.slice(2)); } catch (e) { out({ ev: 'error', message: `bad_args: ${e.message}` }); out({ ev: 'exit', code: 2 }); return 2; }
  const { meeting, adapter } = resolveMeeting(o.url);
  const wav = ensureWav(o.wav);
  const driver = createDriver({
    adapter, url: meeting.link, displayName: o.name, log, captions: false, chat: Boolean(o.say),
    browser: { headless: o.headless, profileDir: null, args: [`--use-file-for-fake-audio-capture=${path.resolve(wav)}`] },
    joinOpts: { micOn: true },
  });
  driver.on('state', (s) => out({ ev: 'state', state: s }));
  let done;
  const finished = new Promise((r) => { done = r; });
  driver.on('disconnected', (why) => { out({ ev: 'error', message: String(why) }); done(why === 'meeting_ended' ? 0 : 1); });
  try {
    await driver.join();
  } catch (e) {
    out({ ev: 'error', message: `join_failed: ${e.code ? `${e.code}: ` : ''}${e.message}` });
    await driver.leave();
    out({ ev: 'exit', code: 1 });
    return 1;
  }
  out({ ev: 'ready', name: o.name, wav: path.basename(wav) });
  if (o.say) { for (const line of o.say.split('|')) { await driver.sendChat(line); } }
  const t = setTimeout(() => done(0), o.minutes * 60_000);
  process.once('SIGINT', () => done(0));
  process.once('SIGTERM', () => done(0));
  const rl = readline.createInterface({ input: process.stdin });
  rl.on('line', (l) => { try { if (JSON.parse(l)?.cmd === 'stop') done(0); } catch { /* */ } });
  const code = await finished;
  clearTimeout(t);
  rl.close();
  process.stdin.unref?.();
  await driver.leave();
  out({ ev: 'exit', code });
  return code;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then((c) => { process.exitCode = c; setTimeout(() => process.exit(c), 1500).unref(); }, (e) => { out({ ev: 'error', message: e.message }); process.exitCode = 1; });
}
