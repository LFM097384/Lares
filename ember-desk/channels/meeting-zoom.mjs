// 会议通道 · Zoom:托管 `node ember-zoom/index.mjs`(webhook + 侧边栏服务器)为受监管子进程,stdin stop。
// configured 当且仅当 ZOOM_CLIENT_ID / ZOOM_CLIENT_SECRET / ZOOM_WEBHOOK_SECRET 都在(env 或 DPAPI 机密)。
// Zoom 没法「按链接加入」:炉灵是经 RTMS 进会的,需要 Zoom App(RTMS)配置,且由会议里的人在 Zoom App 侧边栏邀请 / 主持人启动 RTMS。
import { existsSync } from 'node:fs';
import { spawn as nodeSpawn } from 'node:child_process';
import readline from 'node:readline';
import { ZOOM_ENTRY, REPO } from '../paths.mjs';
import { childEnv } from '../config.mjs';

const NEED = ['ZOOM_CLIENT_ID', 'ZOOM_CLIENT_SECRET', 'ZOOM_WEBHOOK_SECRET'];

export default function meetingZoom(ctx) {
  const env = ctx.env ?? process.env;
  const ov = ctx.overrides?.zoom ?? {};
  const spawn = ov.spawn ?? nodeSpawn;
  const entry = ov.entry ?? ZOOM_ENTRY;
  const has = () => NEED.every((k) => String(ctx.secrets?.[k] ?? '').trim());
  let child = null;
  let listening = null;
  let lastExit = null;

  const ch = {
    id: 'meeting-zoom',
    kind: 'meeting',
    name: 'Zoom 会议(RTMS)',
    describe: () => 'Zoom 经 RTMS 接入:本机托管 ember-zoom 服务器(webhook + Zoom App 侧边栏),由会议里的人从 Zoom App 侧边栏邀请炉灵',
    configured: () => existsSync(entry) && has(),
    async start() {
      if (child) return;
      if (!ch.configured()) throw Object.assign(new Error('Zoom 未配置:需要 ZOOM_CLIENT_ID / ZOOM_CLIENT_SECRET / ZOOM_WEBHOOK_SECRET'), { status: 400 });
      const c = spawn(ov.command ?? process.execPath, [entry], { env: childEnv(ctx.secrets, env, { PORT: String(ctx.config().zoomPort ?? 8790), ...(ov.env ?? {}) }), stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true, cwd: REPO });
      child = c;
      listening = null;
      c.stdin?.on('error', () => {});
      readline.createInterface({ input: c.stdout }).on('line', (l) => {
        let m; try { m = JSON.parse(l); } catch { return; }
        if (m?.ev === 'listening') { listening = { port: m.port, host: m.host }; ctx.log?.(`zoom server listening ${m.host}:${m.port}`); ctx.changed?.(ch); }
        if (m?.ev === 'released') ctx.emit?.({ kind: 'released', title: '纪要已放行', text: `Zoom 会议放行了 ${Number(m.items) || 0} 条纪要` });
      });
      c.on('exit', (code) => { if (child === c) { child = null; listening = null; lastExit = code; ctx.log?.(`zoom server exit ${code}`); ctx.changed?.(ch); } });
      c.on('error', (e) => { if (child === c) { child = null; lastExit = `spawn: ${e.message}`; } });
    },
    async stop({ timeoutMs = 10_000 } = {}) {
      const c = child;
      if (!c) return;
      await new Promise((resolve) => {
        const t = setTimeout(() => { try { c.kill(); } catch { /* */ } }, timeoutMs);
        t.unref?.();
        c.once('exit', () => { clearTimeout(t); resolve(); });
        try { c.stdin.write('{"cmd":"stop"}\n'); } catch { try { c.kill(); } catch { /* */ } }
      });
    },
    status() {
      let detail;
      if (!existsSync(entry)) detail = '找不到 ember-zoom/index.mjs';
      else if (!has()) detail = '未配置:需要 ZOOM_CLIENT_ID / ZOOM_CLIENT_SECRET / ZOOM_WEBHOOK_SECRET(setup-secrets.ps1)';
      else if (child) detail = listening ? `服务器运行中 ${listening.host}:${listening.port}(webhook + 侧边栏)` : '服务器启动中…';
      else detail = `已配置,服务器未运行${lastExit !== null ? `(上次退出 ${lastExit})` : ''}`;
      return { running: Boolean(child), detail };
    },
    prepareJoin(parsed) {
      const running = child ? (listening ? `本机 ember-zoom 服务器正在运行(${listening.host}:${listening.port})。` : '本机 ember-zoom 服务器正在启动。') : (has() ? '本机 ember-zoom 服务器未运行,可在通道里启动「Zoom 会议(RTMS)」。' : 'Zoom 还没配置(缺 ZOOM_CLIENT_ID / ZOOM_CLIENT_SECRET / ZOOM_WEBHOOK_SECRET)。');
      throw Object.assign(new Error(
        `Zoom 会议(${parsed.meetingId})不能按链接直接加入:炉灵经 Zoom RTMS 接入,需要先在 Zoom Marketplace 配好 RTMS App(webhook 指向本机服务器的 HTTPS 隧道),`
        + `再由会议主持人开启 RTMS,或由参会者在 Zoom App 侧边栏里点「邀请炉灵」。${running}`), { status: 400, code: 'zoom_needs_rtms' });
    },
  };
  return ch;
}
