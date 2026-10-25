import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { readFileSync, existsSync, writeFileSync } from 'node:fs';
import { tmpDir, cleanEnv, stubRun } from './helpers.mjs';
import { DEFAULT_CONFIG, loadSecrets, childEnv, ensureToken, normalizeConfig } from '../config.mjs';
import inputMic, { parseDshowAudio, dayFile } from '../channels/input-mic.mjs';
import outputToast, { WINRT_SCRIPT } from '../channels/output-toast.mjs';
import outputTts, { wavFromPcm16 } from '../channels/output-tts.mjs';
import meetingZoom from '../channels/meeting-zoom.mjs';
import outputFeed, { RING } from '../channels/output-feed.mjs';

const baseCtx = (dir, extra = {}) => ({ config: () => ({ ...DEFAULT_CONFIG }), secrets: {}, env: cleanEnv(), stateDir: dir, log: () => {}, emit: () => {}, changed: () => {}, overrides: {}, ...extra });

test('secrets: env first, alias, DPAPI fallback via injected decrypt; childEnv injects both LLM key names', async (t) => {
  const dir = tmpDir(t);
  const s0 = await loadSecrets(dir, { env: { LARES_AI_LLM_API_KEY: 'k1' }, decrypt: async () => { throw new Error('no file → not called'); } });
  assert.equal(s0.LARES_AI_LLM_KEY, 'k1');
  writeFileSync(path.join(dir, 'secrets.dpapi.json'), '{}');
  const s = await loadSecrets(dir, { env: { LARES_AI_LLM_KEY: 'envkey' }, decrypt: async () => ({ LARES_AI_LLM_KEY: 'dp', LARES_DASHSCOPE_API_KEY: 'ds', EVIL: 'x' }) });
  assert.equal(s.LARES_AI_LLM_KEY, 'envkey');
  assert.equal(s.LARES_DASHSCOPE_API_KEY, 'ds');
  assert.equal(s.EVIL, undefined);
  assert.equal(JSON.stringify(s).includes('dp'), false);
  const e = childEnv(s, { PATH: 'p' });
  assert.equal(e.LARES_AI_LLM_API_KEY, 'envkey');
  assert.equal(e.LARES_DASHSCOPE_API_KEY, 'ds');
  assert.equal(normalizeConfig({ defaultK: 99, asr: 'x', jitsiHosts: ['A.b:1'] }).defaultK, null);
  assert.deepEqual(normalizeConfig({ jitsiHosts: ['A.b:1'] }).jitsiHosts, ['a.b:1']);
  const tok = ensureToken(dir, { platform: 'linux' });
  assert.equal(ensureToken(dir), tok);
});

test('mic: degrades without ffmpeg / key / device; streams PCM to ASR and appends notes (local only)', async (t) => {
  const dir = tmpDir(t);
  assert.equal(inputMic(baseCtx(dir, { overrides: { mic: { ffmpegOk: false } } })).configured(), false);
  assert.equal(inputMic(baseCtx(dir, { overrides: { mic: { ffmpegOk: true } } })).configured(), false); // 无 key
  const noDev = inputMic(baseCtx(dir, { secrets: { LARES_DASHSCOPE_API_KEY: 'x' }, overrides: { mic: { ffmpegOk: true, listDevices: () => [] } } }));
  await assert.rejects(noDev.start(), /麦克风/);
  assert.deepEqual(parseDshowAudio('[in#0 @ 0] "HD Webcam" (video)\n[in#0 @ 0] "麦克风 (HyperX Cloud III)" (audio)\n[in#0 @ 0]   Alternative name "@device"'), ['麦克风 (HyperX Cloud III)']);

  const sent = [];
  let onFinal;
  const asr = { open: (o) => { onFinal = o.onFinal; return { send: (pcm) => sent.push(pcm.length), finish: async () => {}, close: () => {} }; } };
  let spawned;
  const fakeSpawn = (cmd, args) => {
    const p = new EventEmitter();
    p.stdout = new PassThrough();
    p.stdin = new PassThrough();
    p.stdin.on('data', (d) => { if (String(d) === 'q') setTimeout(() => p.emit('exit', 0), 5); });
    p.kill = () => p.emit('exit', null);
    spawned = { cmd, args, p };
    return p;
  };
  const feed = [];
  const ch = inputMic(baseCtx(dir, { emit: (it, o) => feed.push([it, o]), overrides: { mic: { ffmpegOk: true, listDevices: () => ['麦克风 (X)'], asr, spawn: fakeSpawn, now: () => new Date(2026, 9, 25, 9, 5) } } }));
  assert.equal(ch.configured(), true);
  await ch.start();
  assert.equal(spawned.cmd, 'ffmpeg');
  assert.deepEqual(spawned.args.slice(spawned.args.indexOf('-i'), spawned.args.indexOf('-i') + 2), ['-i', 'audio=麦克风 (X)']);
  assert.ok(spawned.args.join(' ').includes('-ar 16000 -f s16le -'));
  spawned.p.stdout.write(Buffer.alloc(3201)); // 奇数字节:余 1 字节留到下一块
  spawned.p.stdout.write(Buffer.alloc(1));
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(sent, [1600, 1]);
  assert.equal(ch.status().running, true);
  onFinal('记得买牛奶');
  const nf = path.join(dir, 'notes', dayFile(new Date(2026, 9, 25)));
  assert.equal(readFileSync(nf, 'utf8'), '- 09:05 记得买牛奶\n');
  assert.equal(feed[0][0].kind, 'note');
  assert.deepEqual(feed[0][1], { outputs: false });
  await ch.stop();
  assert.equal(ch.status().running, false);
});

test('toast: payload via env (never interpolated), rate limited, degrades to feed on failure', async () => {
  const calls = [];
  let now = 1_000_000;
  const ch = outputToast(baseCtx('x', { overrides: { toast: { run: stubRun(calls), engine: 'winrt', now: () => now } } }));
  assert.equal(await ch.send({ title: 't', text: 'x' }), false, 'not running');
  await ch.start();
  const evil = '"; Start-Process calc; "$(calc)`';
  assert.equal(await ch.send({ title: evil, text: evil }), true);
  assert.equal(calls[0].script, WINRT_SCRIPT);
  assert.equal(calls[0].exe, 'powershell.exe');
  assert.ok(!calls[0].script.includes('calc'));
  assert.equal(calls[0].payload.title, evil);
  assert.equal(await ch.send({ title: 'b', text: 'b' }), false, 'rate limited (3 s gap)');
  now += 3500;
  assert.equal(await ch.send({ title: 'c', text: 'c' }), true);
  const failing = outputToast(baseCtx('x', { overrides: { toast: { run: async () => ({ code: 1, stdout: '' }) } } }));
  await failing.start();
  assert.equal(await failing.send({ title: 'a', text: 'b' }), false);
  assert.match(failing.status().detail, /feed|上次失败/);
});

test('tts: DashScope PCM → WAV → SoundPlayer; SAPI fallback; WAV header', async () => {
  const calls = [];
  const ch = outputTts(baseCtx('x', { secrets: { LARES_DASHSCOPE_API_KEY: 'k' }, overrides: { tts: { run: stubRun(calls), dashscope: async () => ({ pcm: new Int16Array([1, 2, 3]), sampleRate: 24000 }) } } }));
  const r = await ch.speak('你好');
  assert.deepEqual(r, { ok: true, engine: 'dashscope' });
  assert.match(calls[0].script, /SoundPlayer/);
  assert.ok(!existsSync(calls[0].payload.path), 'temp wav removed');
  const ch2 = outputTts(baseCtx('x', { secrets: { LARES_DASHSCOPE_API_KEY: 'k' }, overrides: { tts: { run: stubRun(calls), dashscope: async () => { throw new Error('net'); } } } }));
  assert.equal((await ch2.speak('x')).engine, 'sapi');
  const w = wavFromPcm16(new Int16Array([0, 1]), 24000);
  assert.equal(w.length, 48);
  assert.equal(w.toString('ascii', 0, 4), 'RIFF');
  assert.equal(w.readUInt32LE(24), 24000);
});

test('zoom: configured iff the three secrets present; supervised child with stdin stop; join explains RTMS', async (t) => {
  const dir = tmpDir(t);
  assert.equal(meetingZoom(baseCtx(dir)).configured(), false);
  const secrets = { ZOOM_CLIENT_ID: 'a', ZOOM_CLIENT_SECRET: 'b', ZOOM_WEBHOOK_SECRET: 'c' };
  let child;
  const fakeSpawn = (cmd, args, o) => {
    const p = new EventEmitter();
    p.stdout = new PassThrough();
    p.stdin = new PassThrough();
    p.env = o.env;
    p.stdin.on('data', (d) => { if (/"stop"/.test(String(d))) setTimeout(() => p.emit('exit', 0), 5); });
    p.kill = () => p.emit('exit', null);
    child = p;
    return p;
  };
  const ch = meetingZoom(baseCtx(dir, { secrets, overrides: { zoom: { spawn: fakeSpawn } } }));
  assert.equal(ch.configured(), true);
  assert.throws(() => ch.prepareJoin({ meetingId: '123' }), (e) => e.status === 400 && /未运行/.test(e.message));
  await ch.start();
  assert.equal(child.env.ZOOM_CLIENT_ID, 'a');
  child.stdout.write('{"ev":"listening","port":8790,"host":"127.0.0.1"}\n');
  await new Promise((r) => setTimeout(r, 20));
  assert.match(ch.status().detail, /8790/);
  assert.throws(() => ch.prepareJoin({ meetingId: '123' }), /正在运行/);
  await ch.stop();
  assert.equal(ch.status().running, false);
});

test('feed ring keeps the last 500', async (t) => {
  const dir = tmpDir(t);
  const f = outputFeed(baseCtx(dir));
  for (let i = 0; i < RING + 60; i++) f.append({ kind: 'k', title: 't', text: String(i) });
  const all = f.read(1000);
  assert.ok(all.length <= RING);
  assert.equal(all.at(-1).text, String(RING + 59));
  const lines = readFileSync(path.join(dir, 'feed.jsonl'), 'utf8').trim().split('\n').length;
  assert.ok(lines <= RING + 51);
});
