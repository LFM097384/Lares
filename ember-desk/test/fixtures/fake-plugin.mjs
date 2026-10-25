// 测试夹具:模仿 ember-jitsi 的进程约定(stdout JSON 事件、stdin {"cmd":"stop"}、退出码)。
// FAKE_MODE: ok(默认,ready 后等 stop)| fail(ready 前报错退出 1)| crash(ready 后退出 1)| hang(ready 后不理 stop)| noready(不 ready 直接退出 0)
// FAKE_ARGS_FILE:把 argv 写进去(检查参数拼装)
import { writeFileSync } from 'node:fs';
import readline from 'node:readline';

const mode = process.env.FAKE_MODE || 'ok';
const out = (o) => process.stdout.write(`${JSON.stringify(o)}\n`);
if (process.env.FAKE_ARGS_FILE) writeFileSync(process.env.FAKE_ARGS_FILE, JSON.stringify({ argv: process.argv.slice(2), hasKey: Boolean(process.env.LARES_AI_LLM_API_KEY) }));

if (mode === 'fail') { out({ ev: 'error', message: 'start_failed: boom' }); out({ ev: 'exit', code: 1 }); process.exitCode = 1; }
else if (mode === 'noready') { out({ ev: 'exit', code: 0 }); }
else {
  out({ ev: 'host', type: 'active', on: true });
  out({ ev: 'session', sid: 's1' });
  setTimeout(() => {
    out({ ev: 'ready', room: 'r', llm: false, asr: 'none' });
    if (mode === 'crash') setTimeout(() => { out({ ev: 'error', where: 'jitsi', message: 'disconnected' }); process.exit(1); }, 100);
  }, 50);
  const rl = readline.createInterface({ input: process.stdin });
  rl.on('line', (l) => {
    let m; try { m = JSON.parse(l); } catch { return; }
    if (m?.cmd !== 'stop' || mode === 'hang') return;
    out({ ev: 'released', items: 2 });
    out({ ev: 'ended', reason: 'stop' });
    out({ ev: 'exit', code: 0 });
    rl.close();
    process.stdin.unref?.();
    setTimeout(() => process.exit(0), 20);
  });
  if (mode === 'hang') setInterval(() => {}, 1000);
}
