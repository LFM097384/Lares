// ember-desk · 会议会话管理:一次只有一个活动会话。
//   join → parseLink → 对应 meeting 通道的 prepareJoin() 给出 {command,args,env} → 托管子进程(stdio pipe,windowsHide)
//   子进程 stdout 一行一个 JSON 元数据事件;状态 joining →(ready)→ in-meeting →(exit 0)→ ended;exit≠0 或 ready 前出错 → failed;然后回到 idle。
//   leave → 往 stdin 写 {"cmd":"stop"}\n,超时(缺省 15 s)后强杀。Windows 上 SIGTERM = TerminateProcess(硬杀),所以先走 stdin。
import { spawn as nodeSpawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import readline from 'node:readline';
import { parseLink, LinkError } from './links.mjs';

export const STOP_TIMEOUT_MS = 15_000;
const ADAPTER_NAMES = { jitsi: 'Jitsi', zoom: 'Zoom', lares: 'Lares' };

export class SessionError extends Error {
  constructor(status, code, message) { super(message); this.name = 'SessionError'; this.status = status; this.code = code; }
}

const short = (s, n = 200) => String(s ?? '').replace(/\s+/g, ' ').slice(0, n);

export class MeetingSessionManager {
  /**
   * @param {object} o
   * @param {import('./registry.mjs').Registry} o.registry  meeting 通道 id = `meeting-<adapter>`
   * @param {(item:object, opts?:object)=>void} o.notify      feed + 输出通道
   * @param {(info:object)=>void} [o.onChange]               SSE 'session'
   * @param {Function} [o.spawn]                             可注入(测试)
   * @param {()=>string[]} [o.jitsiHosts]
   * @param {Function} [o.probe]                             links.parseLink 的探测器
   */
  constructor({ registry, notify = () => {}, onChange = () => {}, spawn = nodeSpawn, jitsiHosts = () => [], probe, stopTimeoutMs = STOP_TIMEOUT_MS, log = () => {} } = {}) {
    Object.assign(this, { registry, notify, onChange, spawnImpl: spawn, jitsiHosts, probe, stopTimeoutMs, log });
    this.session = null;   // 公开的 SessionInfo(活动中)
    this.lastSession = null;
    this.child = null;
    this._leaving = false;
    this._exited = null;   // Promise,子进程退出时 resolve
  }

  get state() {
    if (!this.session) return 'idle';
    if (this._leaving) return 'leaving';
    return this.session.state;
  }

  get live() { return Boolean(this.session && this.session.state === 'in-meeting'); }

  info(s = this.session) { return s ? { ...s, events: [...s.events] } : null; }

  async join({ link, k, convenerName } = {}) {
    if (this.session) throw new SessionError(409, 'busy', `已经在会议里了(${this.session.room ?? this.session.adapter}),先离会再加入新的`);
    if (k !== undefined && k !== null && !(Number.isInteger(k) && k >= 1 && k <= 20)) throw new SessionError(400, 'bad_k', 'k 必须是 1..20 的整数');
    if (convenerName !== undefined && convenerName !== null && (typeof convenerName !== 'string' || convenerName.length > 64 || /[\u0000-\u001f\u007f]/.test(convenerName))) throw new SessionError(400, 'bad_convener', '召集人名字不合法(最长 64 个字符)');
    let parsed;
    try {
      parsed = await parseLink(link, { jitsiHosts: this.jitsiHosts(), ...(this.probe !== undefined ? { probe: this.probe } : {}) });
    } catch (e) {
      if (e instanceof LinkError) throw new SessionError(400, e.code, e.message);
      throw e;
    }
    if (this.session) throw new SessionError(409, 'busy', '已经在会议里了');
    const ch = this.registry.get(`meeting-${parsed.adapter}`);
    if (!ch) throw new SessionError(400, 'no_adapter', `没有 ${ADAPTER_NAMES[parsed.adapter] ?? parsed.adapter} 会议通道`);
    if (typeof ch.prepareJoin !== 'function') throw new SessionError(400, 'unsupported', ch.describe());
    let spec;
    try { spec = await ch.prepareJoin(parsed, { k: k ?? null, convenerName: convenerName ?? null }); } catch (e) {
      throw new SessionError(e.status ?? 400, e.code ?? 'adapter_refused', e.message);
    }
    return this._spawn(parsed, spec);
  }

  _spawn(parsed, spec) {
    const s = {
      id: randomBytes(6).toString('hex'), adapter: parsed.adapter, link: parsed.link, room: parsed.room ?? parsed.meetingId ?? null,
      state: 'joining', startedAt: new Date().toISOString(), endedAt: null, exitCode: null, error: null, events: [],
      released: 0,
    };
    let child;
    try {
      child = this.spawnImpl(spec.command, spec.args, { env: spec.env, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true, cwd: spec.cwd });
    } catch (e) {
      throw new SessionError(500, 'spawn_failed', `启动会议插件失败:${short(e.message)}`);
    }
    this.session = s;
    this.child = child;
    this._leaving = false;
    const stderrTail = [];
    let resolveExit;
    this._exited = new Promise((r) => { resolveExit = r; });
    const rl = readline.createInterface({ input: child.stdout });
    rl.on('line', (line) => this._onLine(s, line));
    child.stderr?.on('data', (d) => {
      for (const l of String(d).split(/\r?\n/)) if (l.trim()) { stderrTail.push(short(l, 300)); if (stderrTail.length > 5) stderrTail.shift(); }
    });
    child.stdin?.on('error', () => { /* 子进程已退出 */ });
    let settled = false;
    const finish = (code, signal, err) => {
      if (settled) return;
      settled = true;
      clearTimeout(this._killTimer);
      const ready = s.events.includes('ready');
      s.exitCode = code ?? null;
      s.endedAt = new Date().toISOString();
      if (err) s.error = s.error ?? short(`spawn: ${err.message}`);
      // 正常结束:进过会且 exit 0;或用户主动离会(含超时强杀)。其余(exit≠0、ready 前退出)= failed
      const ok = !err && ((code === 0 && ready) || (this._leaving && (code === 0 || this._forceKilled)));
      s.state = ok ? 'ended' : 'failed';
      if (ok && this._forceKilled) s.error = '离会超时,已强制结束插件进程';
      if (s.state === 'failed' && !s.error) s.error = code === null ? `killed(${signal ?? '?'})` : (ready ? `插件异常退出(code ${code})` : `未能进会(code ${code})`);
      if (s.state === 'failed' && stderrTail.length) this.log(`session ${s.id} stderr tail: ${stderrTail.join(' | ')}`);
      this.log(`session ${s.id} ${s.state} exit=${code} signal=${signal ?? ''} forced=${Boolean(this._forceKilled)}`);
      const where = s.room ? `「${s.room}」` : '';
      if (s.state === 'ended') this.notify({ kind: 'meeting_ended', title: '炉灵已离会', text: `${ADAPTER_NAMES[s.adapter]} 会议${where}已结束${s.released ? `,放行纪要 ${s.released} 条` : ''}` });
      else this.notify({ kind: 'meeting_failed', title: '炉灵进会失败', text: `${ADAPTER_NAMES[s.adapter]} 会议${where}:${s.error}` });
      this.lastSession = s;
      this.session = null;
      this.child = null;
      this._leaving = false;
      this._forceKilled = false;
      this.onChange(this.info(s));
      resolveExit(this.info(s));
    };
    child.on('error', (e) => finish(null, null, e));
    child.on('exit', (code, signal) => {
      // 等 stdout 读完再定状态(ready 可能还在管道里)
      const done = () => finish(code, signal);
      if (child.stdout && !child.stdout.readableEnded) { child.stdout.once('end', done); setTimeout(done, 500).unref?.(); } else done();
    });
    this.log(`session ${s.id} spawned adapter=${s.adapter} pid=${child.pid ?? '?'}`);
    this.onChange(this.info(s));
    return this.info(s);
  }

  _onLine(s, line) {
    let m;
    try { m = JSON.parse(line); } catch { return; }
    if (!m || typeof m.ev !== 'string') return;
    const ev = m.ev.slice(0, 32);
    if (!s.events.includes(ev)) s.events.push(ev);
    switch (ev) {
      case 'ready':
        if (s.state === 'joining') {
          s.state = 'in-meeting';
          this.notify({ kind: 'meeting_joined', title: '炉灵已进会', text: `已加入 ${ADAPTER_NAMES[s.adapter]} 会议${s.room ? `「${s.room}」` : ''}` });
          this.onChange(this.info(s));
        }
        break;
      case 'released': {
        const n = Number.isInteger(m.items) ? m.items : 0;
        s.released += n;
        this.notify({ kind: 'released', title: '纪要已放行', text: `放行了 ${n} 条纪要` });
        this.onChange(this.info(s));
        break;
      }
      case 'error':
        if (!s.error) s.error = short(m.message ?? m.where ?? 'error');
        break;
      default: break;
    }
  }

  async leave({ timeoutMs = this.stopTimeoutMs } = {}) {
    const child = this.child;
    if (!this.session || !child) return { ok: true, session: this.info(this.lastSession) };
    const exited = this._exited;
    if (!this._leaving) {
      this._leaving = true;
      this.onChange(this.info());
      try { child.stdin.write('{"cmd":"stop"}\n'); } catch { /* */ }
      this._killTimer = setTimeout(() => {
        this._forceKilled = true;
        this.log('session stop timeout → force kill');
        try { child.kill(); } catch { /* */ }
      }, timeoutMs);
      this._killTimer.unref?.();
    }
    const info = await exited;
    return { ok: true, session: info };
  }

  /// 守护进程退出时:优雅停,再兜底硬杀
  async shutdown(timeoutMs) {
    if (this.child) await this.leave({ timeoutMs: timeoutMs ?? this.stopTimeoutMs });
  }
}
