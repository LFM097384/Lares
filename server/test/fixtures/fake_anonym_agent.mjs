// 测试专用:假的隐名之约 agent 进程(LARES_ANONYM_AGENT_ENTRY 指向它)。
// 只模拟信令面:challenge → hello(auth + aiAuth)→ join → anon_agent_hello;收到 anon_agent_key 记下来。
// 测试通过 FAKE_AGENT_DIR/<cid>/cmd.jsonl 追加命令驱动它(每行一个 JSON 消息,原样发给服务器);
// 启动时把 env 与 argv 写到 FAKE_AGENT_DIR/<cid>/env.json,收到的消息追加到 FAKE_AGENT_DIR/<cid>/inbox.jsonl。
import crypto from 'node:crypto';
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import WebSocket from 'ws';

const argv = process.argv.slice(2);
const arg = (k) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : undefined; };
const circleId = arg('--circle');
const url = arg('--signaling');
const userId = process.env.LARES_ANONYM_USER_ID;
const dir = path.join(process.env.FAKE_AGENT_DIR, circleId); // 每圈一个子目录
mkdirSync(dir, { recursive: true });
writeFileSync(path.join(dir, 'env.json'), JSON.stringify({ env: process.env, argv, pid: process.pid }));
const hmac = (k, s) => crypto.createHmac('sha256', k).update(s).digest('hex');
const note = (m) => appendFileSync(path.join(dir, 'inbox.jsonl'), JSON.stringify(m) + '\n');

const ws = new WebSocket(url);
// 重启后不重放旧命令
let done = existsSync(path.join(dir, 'cmd.jsonl')) ? readFileSync(path.join(dir, 'cmd.jsonl'), 'utf8').split('\n').filter(Boolean).length : 0;
function pump() {
  const f = path.join(dir, 'cmd.jsonl');
  if (!existsSync(f) || ws.readyState !== WebSocket.OPEN) return;
  const lines = readFileSync(f, 'utf8').split('\n').filter(Boolean);
  for (; done < lines.length; done++) {
    const m = JSON.parse(lines[done]);
    if (m.cmd === 'exit') process.exit(m.code ?? 0);
    ws.send(JSON.stringify({ circleId, ...m }));
  }
}
setInterval(pump, 50);
ws.on('message', (raw) => {
  const m = JSON.parse(String(raw));
  note(m);
  if (m.t === 'challenge') {
    const auth = m.authRequired === false ? undefined : {
      mode: 'circle', nonce: m.nonce, circleId, v: Number(process.env.LARES_AI_AUTH_V) === 2 ? 2 : undefined,
      proof: hmac(process.env.LARES_AI_AUTH_SECRET, `${m.nonce}:${userId}:${circleId}`),
    };
    const aiAuth = { circleId, proof: hmac(process.env.LARES_AI_MEMBER_SECRET, `${m.nonce}:${userId}:${circleId}`) };
    ws.send(JSON.stringify({ t: 'hello', userId, deviceId: 'd-anon', name: '隐名', platform: 'ai', auth, aiAuth }));
  } else if (m.t === 'welcome') {
    ws.send(JSON.stringify({ t: 'join', circleId }));
  } else if (m.t === 'room' && m.circleId === circleId) {
    ws.send(JSON.stringify({ t: 'anon_agent_hello', circleId, x25519Pub: process.env.FAKE_AGENT_PUB || 'cHViLWtleS1mYWtl' }));
  }
});
ws.on('close', () => process.exit(0));
process.stdin.on('data', (b) => { if (String(b).includes('"stop"')) process.exit(0); });
process.on('SIGTERM', () => process.exit(0));
