// lares.ai-voice 监管器单测(假 spawn + 假时钟,无网络)+ 内置插件 manifest / normalizeConfig 检查。
// 契约:server/bots/voice-agent/CONTRACT.md §1/§2/§4。
// 用法:node test/ai_voice_supervisor.mjs

import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { makeChecker } from './lib/harness.mjs';
import {
  createAiVoiceSupervisor, nextLocalMidnight, isAiUserId,
  EMPTY_GRACE_MS, KILL_AFTER_MS, BACKOFF_MIN_MS, BACKOFF_MAX_MS,
} from '../src/ai_voice_supervisor.js';
import { BUILTINS, validateManifest, pluginView } from '../src/plugins.js';
import { normalizeAiVoiceConfig, AI_VOICE_DEFAULTS } from '../src/ai_voice_config.js';
import * as botConfig from '../bots/voice-agent/config.mjs';

const T = makeChecker();
const { check } = T;
const S = 1000;

// ── 假时钟 + 假计时器 ──
function fakeClock(start = Date.UTC(2026, 9, 3, 4, 0, 0)) {
  const c = { t: start, timers: new Map(), seq: 0 };
  c.now = () => c.t;
  c.setTimer = (fn, ms) => { const id = ++c.seq; c.timers.set(id, { at: c.t + ms, fn }); return id; };
  c.clearTimer = (id) => { c.timers.delete(id); };
  c.adv = (ms) => {
    const end = c.t + ms;
    for (;;) {
      let next = null;
      for (const [id, x] of c.timers) if (x.at <= end && (!next || x.at < next[1].at)) next = [id, x];
      if (!next) break;
      c.timers.delete(next[0]);
      c.t = next[1].at;
      next[1].fn();
    }
    c.t = end;
  };
  return c;
}

// ── 假子进程 ──
function fakeSpawner() {
  const calls = [];
  const spawn = (cmd, args, opts) => {
    const child = new EventEmitter();
    child.pid = 1000 + calls.length;
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    child.stdinLines = [];
    child.stdin = { write: (s) => { child.stdinLines.push(s); return true; }, end: () => {}, on: () => {} };
    child.signals = [];
    child.kill = (sig) => { child.signals.push(sig); return true; };
    child.exit = (code, signal = null) => child.emit('exit', code, signal);
    calls.push({ cmd, args, opts, child });
    return child;
  };
  return { spawn, calls, last: () => calls[calls.length - 1]?.child };
}

function setup(over = {}) {
  const clock = fakeClock();
  const sp = fakeSpawner();
  const world = {
    enabled: true, humans: 1, e2ee: false, config: { ...AI_VOICE_DEFAULTS, name: '阿福' },
    auth: { secret: 'f'.repeat(64), v: 2 },
  };
  const logs = [];
  const sup = createAiVoiceSupervisor({
    env: { LARES_DASHSCOPE_API_KEY: 'sk-test-SECRET', LIVEKIT_API_SECRET: 'lk-SECRET', LARES_AI_MEMBER_KEY: 'mk-SECRET', PATH: 'x',
      LARES_AI_LLM_KEY: 'sk-llm-SECRET', LARES_AI_LLM_BASE_URL: 'https://api.deepseek.com', LARES_AI_LLM_MODEL: 'deepseek-flash', LARES_AI_LLM_EXTRA_BODY: '{"x":1}', ...(over.env ?? {}) },
    dataDir: '/data',
    botEntry: '/srv/bots/voice-agent/index.mjs',
    botEntryExists: () => true,
    signalingUrl: 'ws://127.0.0.1:8787/ws',
    isEnabled: () => world.enabled,
    configOf: () => world.config,
    humanCount: () => world.humans,
    circleE2ee: () => world.e2ee,
    authFor: () => world.auth,
    memberSecretFor: (cid) => `member-${cid}-e`.padEnd(40, 'e'),
    spawn: sp.spawn,
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
    tzOffsetMin: 480,
    execPath: 'node',
    log: { log: (m) => logs.push(m), error: (m) => logs.push(m) },
  });
  return { sup, clock, sp, world, logs };
}
const CID = 'c_abcdefghijklmnopqrstuvwxyz';
const tick = () => new Promise((r) => setImmediate(r));

console.log('— 内置插件 manifest / normalizeConfig');
{
  const b = BUILTINS['lares.ai-voice'];
  check(Boolean(b), 'BUILTINS 含 lares.ai-voice');
  const v = validateManifest(JSON.parse(JSON.stringify(b.manifest)), { allowReserved: true });
  check(v.ok, 'manifest 通过 validateManifest(allowReserved)', v);
  check(/DashScope/.test(b.manifest.description) && /E2EE/.test(b.manifest.description), 'description 提到 DashScope 与 E2EE', b.manifest.description);
  check(b.manifest.settingsSchema?.properties?.trigger?.enum?.join() === 'wake,always,ptt', 'schema trigger enum');
  const d0 = b.normalizeConfig({});
  check(d0.ok && d0.config.name === '小助手' && d0.config.trigger === 'wake' && d0.config.maxReplyChars === 120, '空 config → 默认值', d0);
  const c = b.normalizeConfig({ maxReplyChars: 5, maxTurnsPerHour: 9999, maxTurnsPerDay: 0, trigger: 'nope', name: '一二三四五六七八九十一二三四五六七八', interrupt: 'x', bogus: 1, voice: 'bad voice!' });
  check(c.ok && c.config.maxReplyChars === 20 && c.config.maxTurnsPerHour === 200 && c.config.maxTurnsPerDay === 1, 'int 夹紧', c);
  check(c.config.trigger === 'wake' && [...c.config.name].length === 16 && c.config.interrupt === true && !('bogus' in c.config) && c.config.voice === 'Cherry', '非法值回落默认 / 截断 / 丢未知字段', c);
  check(normalizeAiVoiceConfig(null).ok === false && normalizeAiVoiceConfig([]).ok === false, '非对象 → 失败');
  check(botConfig.normalizeAiVoiceConfig === normalizeAiVoiceConfig, 'bots/voice-agent/config.mjs 转出同一实现');
  const view = pluginView({ manifest: b.manifest, builtin: true, enabled: true, config: d0.config });
  check(!/sk-|secret|verifier|passcode/i.test(JSON.stringify(view.config)), 'pluginView config 不含密钥字段');
  check(isAiUserId('u_ai_12345678') && !isAiUserId('u_123'), 'isAiUserId');
}

console.log('— 启动条件 / argv 无密钥');
{
  const { sup, sp, world, logs } = setup();
  world.enabled = false;
  sup.reconcile(CID);
  check(sp.calls.length === 0, '未启用 → 不启动');
  world.enabled = true; world.humans = 0;
  sup.reconcile(CID);
  check(sp.calls.length === 0, '房里没人 → 不启动');
  world.humans = 1; world.e2ee = true;
  sup.reconcile(CID);
  sup.reconcile(CID);
  check(sp.calls.length === 0, 'E2EE 圈 → 拒绝');
  check(logs.filter((m) => /E2EE/.test(m)).length === 1, 'E2EE 拒绝只记一次日志', logs);
  check(sup.status(CID).refusal === 'e2ee', 'status.refusal = e2ee');
  world.e2ee = false;
  sup.reconcile(CID);
  check(sp.calls.length === 1, '启用 + 有人 + 非 E2EE → 启动');
  const { args, opts } = sp.calls[0];
  const argv = args.join(' ');
  check(!argv.includes('ffff') && !argv.includes('sk-test') && !argv.includes('SECRET'), 'argv 不含任何密钥', args);
  check(args.includes('--circle') && args.includes(CID), 'argv 带 --circle', args);
  check(opts.env.LARES_AI_AUTH_SECRET === 'f'.repeat(64) && opts.env.LARES_AI_AUTH_V === '2', 'env 带鉴权 secret / v');
  check(opts.env.LARES_DASHSCOPE_API_KEY === 'sk-test-SECRET', 'env 继承 DashScope key');
  check(!('LIVEKIT_API_SECRET' in opts.env) && !('LARES_AI_MEMBER_KEY' in opts.env), 'env 不泄露 LiveKit secret / 主钥匙');
  check(opts.env.LARES_AI_LLM_KEY === 'sk-llm-SECRET' && opts.env.LARES_AI_LLM_BASE_URL === 'https://api.deepseek.com'
    && opts.env.LARES_AI_LLM_MODEL === 'deepseek-flash' && opts.env.LARES_AI_LLM_EXTRA_BODY === '{"x":1}', 'env 继承 LARES_AI_LLM_*(DeepSeek)');
  check(!argv.includes('sk-llm') && !argv.includes('deepseek'), 'LLM key / 地址不进 argv', args);
  check(opts.env.LARES_AI_MEMBER_SECRET?.startsWith(`member-${CID}`) && !argv.includes('member-'), 'u_ai_ 身份凭证只在 env(按圈),不进 argv');
  check(JSON.parse(opts.env.LARES_AI_CONFIG).name === '阿福', 'env LARES_AI_CONFIG');
  check(/ai_voice_usage[\\/]c_abcdefghijklmnopqrstuvwxyz\.json$/.test(opts.env.LARES_AI_USAGE_FILE), 'usage 文件路径', opts.env.LARES_AI_USAGE_FILE);
  check(opts.env.LARES_SIGNALING === 'ws://127.0.0.1:8787/ws', 'env LARES_SIGNALING');
  sup.reconcile(CID);
  check(sp.calls.length === 1, '重复 reconcile 不重复启动');
  check(sup.status(CID).running === true, 'status.running');
}

console.log('— 缺 DashScope key');
{
  const a = setup({ env: { LARES_DASHSCOPE_API_KEY: '' } });
  a.sup.reconcile(CID);
  check(a.sp.calls.length === 0, '无 key → 拒绝');
  const b = setup({ env: { LARES_DASHSCOPE_API_KEY: '', LARES_AI_PROVIDERS: 'mock' } });
  b.sup.reconcile(CID);
  check(b.sp.calls.length === 1 && b.sp.calls[0].args.includes('mock'), 'mock providers → 允许启动');
  const c = setup();
  c.world.auth = null;
  c.sup.reconcile(CID);
  check(c.sp.calls.length === 0, 'authFor=null → 拒绝');
}

console.log('— 空房宽限 + SIGTERM → SIGKILL');
{
  const { sup, sp, world, clock } = setup();
  sup.reconcile(CID);
  const ch = sp.last();
  world.humans = 0;
  sup.reconcile(CID);
  clock.adv(EMPTY_GRACE_MS - S);
  check(ch.signals.length === 0, '宽限内不停');
  world.humans = 1;
  sup.reconcile(CID);
  clock.adv(EMPTY_GRACE_MS * 2);
  check(ch.signals.length === 0, '宽限内有人回来 → 取消停止');
  world.humans = 0;
  sup.reconcile(CID);
  clock.adv(EMPTY_GRACE_MS);
  check(ch.signals[0] === 'SIGTERM', '宽限到 → SIGTERM', ch.signals);
  check(ch.stdinLines.some((l) => l.trim() === '{"cmd":"stop"}'), 'stdin 收到 stop');
  clock.adv(KILL_AFTER_MS);
  check(ch.signals.includes('SIGKILL'), '5 s 不退 → SIGKILL', ch.signals);
  ch.exit(null, 'SIGKILL');
  check(sp.calls.length === 1 && !sup.status(CID).running, '叫停后的退出不重拉');
  world.humans = 1;
  sup.reconcile(CID);
  check(sp.calls.length === 2, '有人再来 → 重新启动');
  // 停用立即停(无宽限)
  world.enabled = false;
  sup.reconcile(CID);
  check(sp.last().signals[0] === 'SIGTERM', '插件停用 → 立即 SIGTERM');
  sp.last().exit(0);
  check(sp.calls.length === 2, '停用后不重拉');
}

console.log('— 崩溃退避 + 每小时上限');
{
  const { sup, sp, clock } = setup();
  sup.reconcile(CID);
  const delays = [];
  for (let i = 0; i < 5; i++) {
    sp.last().exit(1);
    const before = sp.calls.length;
    const at = sup.status(CID).respawnAt;
    delays.push(at - clock.t);
    clock.adv(at - clock.t - 1);
    check(sp.calls.length === before, `第 ${i + 1} 次崩溃:退避期间不拉起`);
    clock.adv(1);
    check(sp.calls.length === before + 1, `第 ${i + 1} 次崩溃:退避到点拉起`);
  }
  check(delays[0] === BACKOFF_MIN_MS && delays[1] === 2 * BACKOFF_MIN_MS && delays[3] === 8 * BACKOFF_MIN_MS, '退避 5s → 10s → 20s → 40s', delays);
  check(delays.every((x) => x <= BACKOFF_MAX_MS), '退避不超过 60 s', delays);
  sp.last().exit(1); // 1 小时内第 6 次
  const n = sp.calls.length;
  clock.adv(BACKOFF_MAX_MS * 2);
  check(sp.calls.length === n, '一小时 5 次后不再重拉');
  check(sup.status(CID).blockedUntil > clock.t, 'status.blockedUntil');
  clock.adv(3600 * S);
  check(sp.calls.length === n + 1, '窗口过去后恢复');
}

console.log('— exit 4(日额度)到次日才重拉');
{
  const { sup, sp, clock } = setup();
  sup.reconcile(CID);
  sp.last().exit(4);
  sup.reconcile(CID);
  clock.adv(BACKOFF_MAX_MS * 10);
  check(sp.calls.length === 1, 'code 4 后当天不重拉');
  const midnight = nextLocalMidnight(clock.t, 480);
  check(new Date(midnight + 480 * 60_000).toISOString().endsWith('T00:00:00.000Z'), 'nextLocalMidnight = 本地 0 点');
  clock.adv(midnight - clock.t + 2 * S);
  check(sp.calls.length === 2, '过了本地零点 → 重新拉起');
}

console.log('— 未叫停的正常退出(被踢)');
{
  const { sup, sp, world } = setup();
  sup.reconcile(CID);
  sp.last().exit(0);
  sup.reconcile(CID);
  check(sp.calls.length === 1, '自行 exit 0 → 不立刻拉回');
  world.humans = 0; sup.reconcile(CID);
  world.humans = 1; sup.reconcile(CID);
  check(sp.calls.length === 2, '房间清空过一次后再有人 → 重新拉起');
}

console.log('— 配置热更新 + stdout 解析');
{
  const { sup, sp, world, logs } = setup();
  sup.reconcile(CID);
  const ch = sp.last();
  check(sup.onConfig(CID) === false, '配置没变不推');
  world.config = { ...world.config, trigger: 'always' };
  sup.reconcile(CID); // 插件变更走 broadcastLobbySummary → reconcile
  const cfgLine = ch.stdinLines.find((l) => l.includes('"cmd":"config"'));
  check(Boolean(cfgLine) && JSON.parse(cfgLine).config.trigger === 'always' && cfgLine.endsWith('\n'), 'stdin 收到 config 行', ch.stdinLines);
  world.config = { ...world.config, maxReplyChars: 60 };
  check(sup.onConfig(CID) === true, 'onConfig 直接调用也能推');
  ch.stdout.write('{"ev":"turn","id":1,"trigger":"wake","ttfaMs":900,"llmFirstTokenMs":300,"heardChars":8,"replyChars":20}\n{"ev":"usage","day":"2026-10-03","total":{"turns":3}}\nnot json\n');
  ch.stderr.write('some warn\n');
  await tick();
  check(logs.some((m) => m.startsWith('[ai-voice]') && /turn wake ttfa=900ms/.test(m)), 'turn 事件精简记日志', logs);
  check(logs.some((m) => /usage .*turns=3/.test(m)), 'usage 事件记日志');
  check(logs.some((m) => /some warn/.test(m) && m.startsWith('[ai-voice]')), 'stderr 加前缀透传');
}

console.log('— stopAll');
{
  const { sup, sp, world } = setup();
  sup.reconcile(CID);
  sup.reconcile('home');
  sup.stopAll();
  check(sp.calls.every((c) => c.child.signals.includes('SIGTERM')), 'stopAll → 全部 SIGTERM');
  sp.calls[0].child.exit(1);
  world.humans = 2;
  sup.reconcile(CID);
  check(sp.calls.length === 2, 'stopAll 之后不再启动 / 不重拉');
}

console.log('— 全站进程上限(LARES_AI_MAX_PROCESSES)');
{
  const { sup, sp } = setup({ env: { LARES_AI_MAX_PROCESSES: '2' } });
  sup.reconcile('c1'); sup.reconcile('c2'); sup.reconcile('c3');
  check(sp.calls.length === 2, '上限 2:第 3 个圈不启动', sp.calls.length);
  check(sup.status('c3').refusal === 'capacity', 'c3 refusal=capacity', sup.status('c3'));
  sup.reconcile('c1');
  check(sp.calls.length === 2, '已在跑的圈 reconcile 不受上限影响');
  sp.calls[0].child.exit(0); // c1 自行退出 → 腾出名额
  check(sp.calls.length === 3 && sp.calls[2].args.includes('c3'), '腾出名额后排队的 c3 被拉起', sp.calls.map((c) => c.args[2]));
}

console.log(`\n${T.pass} 通过, ${T.fail} 失败`);
process.exit(T.fail ? 1 : 0);
