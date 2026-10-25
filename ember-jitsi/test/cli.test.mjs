import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';
import { parseArgs, scopeOf, meteredAsr, main, UsageError, EXIT, asrFromEnv, llmFromEnv } from '../index.mjs';
import { MockAsr } from '../../ember/index.mjs';
import { playwrightCandidates, chromiumFallbacks } from '../deps.mjs';

test('parseArgs: values and validation', () => {
  assert.deepEqual(parseArgs(['--room', 'abc', '--k', '3', '--url', 'https://meet.example', '--asr', 'mock', '--memory-dir', 'd', '--scope', 's', '--convener-name', '张伟', '--headful']),
    { room: 'abc', k: 3, url: 'https://meet.example', asr: 'mock', memoryDir: 'd', scope: 's', convenerName: '张伟', headful: true });
  assert.deepEqual(parseArgs(['-h']), { help: true });
  assert.deepEqual(parseArgs([]), {});
  for (const bad of [
    ['--room'], ['--room', '--k', '2'], ['--k', '0'], ['--k', '21'], ['--k', '1.5'], ['--k', 'x'],
    ['--room', 'bad room'], ['--room', '房间'], ['--room', 'x'.repeat(65)], ['--asr', 'whisper'],
    ['--url', 'ftp://x'], ['--url', 'not a url'], ['--bogus'],
  ]) assert.throws(() => parseArgs(bad), UsageError, JSON.stringify(bad));
});

test('scopeOf: stable, host-scoped, case-insensitive on room', () => {
  const s = scopeOf('https://meet.example', 'Team.Room');
  assert.match(s, /^[0-9a-f]{24}$/);
  assert.equal(s, scopeOf('https://meet.example', 'Team.Room'));
  assert.equal(s, scopeOf('https://meet.example/other/path', 'team.room'));
  assert.notEqual(s, scopeOf('https://other.example', 'team.room'));
  assert.notEqual(s, scopeOf('https://meet.example', 'team.room2'));
});

test('meteredAsr: emits asr_final {ev, endpoint, chars} without text; passes text on', async () => {
  assert.equal(meteredAsr(null, () => {}), null);
  const evs = [];
  const finals = [];
  const fake = { warmed: 0, warmup() { this.warmed += 1; }, open(o) { setTimeout(() => o.onFinal('秘密的原话'), 0); return { send() {}, close() {} }; } };
  const m = meteredAsr(fake, (e) => evs.push(e));
  m.warmup();
  assert.equal(fake.warmed, 1);
  m.open({ identity: 'ep1', onFinal: (t) => finals.push(t) });
  await new Promise((r) => setTimeout(r, 10));
  assert.deepEqual(evs, [{ ev: 'asr_final', endpoint: 'ep1', chars: 5 }]);
  assert.deepEqual(finals, ['秘密的原话']);
  // emit throwing does not break transcription
  const m2 = meteredAsr(fake, () => { throw new Error('x'); });
  const f2 = [];
  m2.open({ identity: 'ep2', onFinal: (t) => f2.push(t) });
  await new Promise((r) => setTimeout(r, 10));
  assert.deepEqual(f2, ['秘密的原话']);
});

test('asrFromEnv / llmFromEnv: no key → no network objects', async () => {
  assert.equal(await asrFromEnv('none', {}), null);
  assert.ok(await asrFromEnv('mock', {}) instanceof MockAsr);
  await assert.rejects(asrFromEnv('dashscope', {}), UsageError);
  assert.equal(await llmFromEnv({}), null);
});

test('main: missing --room → 2 with {ev:exit,code:2}', async () => {
  const out = [];
  const code = await main([], {}, { out: (e) => out.push(e), run: () => { throw new Error('should not run'); } });
  assert.equal(code, EXIT.BAD_ARGS);
  assert.ok(out.some((e) => e.ev === 'error' && /--room/.test(e.message)));
  assert.deepEqual(out.at(-1), { ev: 'exit', code: 2 });
  const out2 = [];
  assert.equal(await main(['--k', 'zz'], {}, { out: (e) => out2.push(e) }), 2);
  assert.deepEqual(out2.at(-1), { ev: 'exit', code: 2 });
});

test('main: run() UsageError → 2, other error → 1', async () => {
  const out = [];
  assert.equal(await main(['--room', 'r'], {}, { out: (e) => out.push(e), run: async () => { throw new UsageError('LARES_DASHSCOPE_API_KEY missing'); } }), 2);
  assert.deepEqual(out.at(-1), { ev: 'exit', code: 2 });
  assert.equal(await main(['--room', 'r'], {}, { out: (e) => out.push(e), run: async () => { throw new Error('no chromium'); } }), 1);
  assert.ok(out.some((e) => e.ev === 'error' && /start_failed/.test(e.message)));
  assert.deepEqual(out.at(-1), { ev: 'exit', code: 1 });
});

test('main: stdin {"cmd":"stop"} → bot.stop → exit 0', async () => {
  const stdin = new PassThrough();
  const out = [];
  let opts = null;
  let stops = 0;
  const run = async (o) => {
    opts = o;
    let resolve;
    const done = new Promise((r) => { resolve = r; });
    o.emit({ ev: 'ready' });
    return { done, stop: (code) => { stops += 1; resolve(code); return done; } };
  };
  const p = main(['--room', 'r1', '--k', '2', '--asr', 'mock'], { EMBER_JITSI_ASR: 'dashscope' }, { stdin, out: (e) => out.push(e), run });
  await new Promise((r) => setTimeout(r, 10));
  stdin.write('not json\n');
  stdin.write('{"cmd":"other"}\n');
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(stops, 0);
  stdin.write('{"cmd":"stop"}\n');
  assert.equal(await p, 0);
  assert.equal(stops, 1);
  assert.equal(opts.room, 'r1');
  assert.equal(opts.k, 2);
  assert.equal(opts.asrKind, 'mock', '--asr wins over env');
  assert.deepEqual(out, [{ ev: 'ready' }, { ev: 'exit', code: 0 }]);
  stdin.destroy();
});

test('main: EMBER_JITSI_ASR env used when --asr absent', async () => {
  const stdin = new PassThrough();
  let kind = null;
  const code = await main(['--room', 'r1'], { EMBER_JITSI_ASR: 'none' }, {
    stdin, out: () => {}, run: async (o) => { kind = o.asrKind; return { done: Promise.resolve(0), stop: async () => 0 }; },
  });
  assert.equal(code, 0);
  assert.equal(kind, 'none');
  stdin.destroy();
});

test('deps: candidate lists are arrays and honour overrides (no launching)', () => {
  const env = { EMBER_PLAYWRIGHT_DIR: 'X:/pw', EMBER_CHROMIUM_PATH: 'X:/chrome.exe', LOCALAPPDATA: 'X:/nonexistent-local', HOME: 'X:/nonexistent-home', PLAYWRIGHT_BROWSERS_PATH: 'X:/nonexistent-browsers' };
  assert.deepEqual(playwrightCandidates(env), ['X:/pw']);
  assert.deepEqual(chromiumFallbacks(env), ['X:/chrome.exe']);
});
