// lares.ai-voice 端到端(信令层):真服务端进程 + 真 supervisor 拉起 bots/voice-agent(mock provider)。
// 验证:圈主装插件 → 真人进房 → supervisor spawn 子进程 → 子进程用 env 里的凭证(圈 verifier + u_ai_ 身份凭证)
// 通过 hello、进房,房里看到 u_ai_<hash>。LiveKit 用假地址(token 是本地签的 JWT,不联网),
// 所以子进程拿到 token 后连媒体会失败退出 —— 本测试只看信令层(真媒体见 tool/ai_voice_e2e.mjs)。
// 没装 @livekit/rtc-node(optionalDependency)时 bot 无法启动,测试跳过。
// 用法:node test/ai_voice_spawn.mjs    (DEBUG=1 显示服务端 stderr)

import crypto, { randomBytes } from 'node:crypto';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { makeChecker, boot, waitHealth, stop, join, registerCircle, wait } from './lib/harness.mjs';

const T = makeChecker();
const { check } = T;
const PORT = 18977;

let rtcOk = true;
try { await import('@livekit/rtc-node'); } catch { rtcOk = false; }

async function main() {
  console.log('AI 语音助手:supervisor 拉起 bot(mock)→ 信令鉴权 + 进房\n');
  if (!rtcOk) { console.log('  (跳过:未安装 @livekit/rtc-node)'); return; }
  const dataDir = mkdtempSync(path.join(tmpdir(), 'lares-aispawn-'));
  const srv = boot(PORT, dataDir, 'aispawn-global-' + randomBytes(4).toString('hex'), {
    LIVEKIT_URL: 'ws://127.0.0.1:9', // 不可达:只测信令
    LIVEKIT_API_KEY: 'devkey',
    LIVEKIT_API_SECRET: 'secret-secret-secret-secret-secret',
    LARES_AI_PROVIDERS: 'mock',
  });
  const clients = [];
  try {
    check(await waitHealth(PORT), '服务端启动');
    const { cid, ownerKey, owner } = await registerCircle(PORT, 'aispawn-pass-' + randomBytes(4).toString('hex'), 'u_owner');
    clients.push(owner);
    const inst = await owner.req({ t: 'plugin_install', circleId: cid, ownerKey, pluginId: 'lares.ai-voice' }, (m) => m.t === 'plugin_installed' || m.t === 'owner_error');
    check(inst?.t === 'plugin_installed', '圈主装 lares.ai-voice', inst);
    const expectId = `u_ai_${crypto.createHash('sha256').update(cid).digest('hex').slice(0, 8)}`;
    owner.drain(() => true);
    await join(owner, cid); // 真人进房 → supervisor reconcile → spawn
    const joined = await owner.waitFor((m) => m.t === 'member_joined' && m.member?.userId === expectId, 15000);
    check(Boolean(joined), `supervisor 拉起的 bot 通过 hello(u_ai_ 凭证)并进房:${expectId}`, joined ?? srv.out.slice(-1500));
    check(!/userId_reserved|auth_failed/.test(srv.out), '服务端日志无 userId_reserved / auth_failed', srv.out.slice(-1500));
    check(!srv.out.includes('secret-secret-secret'), '日志不含 LiveKit 密钥');
  } finally {
    for (const c of clients) await c.close?.().catch?.(() => {});
    await wait(100);
    await stop(srv);
    if (T.fail && !process.env.DEBUG) console.log(srv.out.slice(-3000));
  }
}

await main();
console.log(T.fail === 0 ? `\n全部通过(${T.pass} 通过)` : `\n${T.pass} 通过,${T.fail} 失败`);
process.exit(T.fail === 0 ? 0 : 1);
