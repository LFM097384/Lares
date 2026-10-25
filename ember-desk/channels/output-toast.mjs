// 输出通道 · Windows 通知。顺序:BurntToast 模块(若已装)→ WinRT toast(Windows PowerShell 5.1;pwsh 7 没有 WinRT 投影)→ 只留消息流(托盘自己弹气泡)。
// 文字经 env base64 JSON 传入,脚本里用 InnerText / 参数绑定,不做字符串插值。限流:两条之间 ≥ 3 s,每分钟 ≤ 10 条,超出的只留在消息流。
// 测试注入 ctx.overrides.toast = { run(exe, script, {payload}) → {code, stdout}, engine }
import { runPs, WINPS, PS_DECODE } from '../ps.mjs';

const POWERSHELL_AUMID = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe';

export const WINRT_SCRIPT = [
  '$ErrorActionPreference = "Stop"',
  PS_DECODE,
  '[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]',
  '[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]',
  '$x = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)',
  '$n = $x.GetElementsByTagName("text")',
  '[void]$n.Item(0).AppendChild($x.CreateTextNode([string]$p.title))',
  '[void]$n.Item(1).AppendChild($x.CreateTextNode([string]$p.text))',
  `[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('${POWERSHELL_AUMID}').Show([Windows.UI.Notifications.ToastNotification]::new($x))`,
  'Write-Output ok',
].join('; ');

export const BURNT_SCRIPT = [
  '$ErrorActionPreference = "Stop"',
  PS_DECODE,
  'Import-Module BurntToast',
  'New-BurntToastNotification -Text ([string]$p.title), ([string]$p.text)',
  'Write-Output ok',
].join('; ');

export const DETECT_SCRIPT = 'if (Get-Module -ListAvailable BurntToast) { "burnttoast" } else { "winrt" }';

export default function outputToast(ctx) {
  const ov = ctx.overrides?.toast ?? {};
  const run = ov.run ?? ((exe, script, o) => runPs(exe, script, o));
  const platformOk = ov.run ? true : process.platform === 'win32';
  let running = false;
  let engine = ov.engine ?? null;
  let last = 0;
  let windowStart = 0;
  let inWindow = 0;
  let sent = 0;
  let dropped = 0;
  let lastError = null;
  const now = ov.now ?? (() => Date.now());

  async function detect() {
    if (engine) return engine;
    const r = await run(WINPS, DETECT_SCRIPT, { timeoutMs: 15_000 });
    engine = r.code === 0 && /burnttoast/.test(r.stdout) ? 'burnttoast' : 'winrt';
    return engine;
  }

  const ch = {
    id: 'toast',
    kind: 'output',
    name: 'Windows 通知',
    describe: () => 'Windows 通知中心弹出提示(BurntToast 或 WinRT);失败时只留在消息流,托盘气泡兜底',
    configured: () => platformOk,
    async start() { running = true; },
    async stop() { running = false; },
    status: () => ({ running, detail: !platformOk ? '仅 Windows' : `${engine ?? '未检测'}${engine === 'feed' ? '(通知不可用,只留消息流)' : ''} · 已发 ${sent} · 限流丢弃 ${dropped}${lastError ? ` · 上次失败 ${lastError}` : ''}` }),
    /// msg: {title, text, kind}
    async send(msg) {
      if (!running) return false;
      const t = now();
      if (t - windowStart > 60_000) { windowStart = t; inWindow = 0; }
      if (t - last < 3000 || inWindow >= 10) { dropped++; return false; }
      last = t; inWindow++;
      const payload = { title: String(msg?.title ?? '炉灵').slice(0, 120), text: String(msg?.text ?? '').slice(0, 400) };
      const eng = await detect();
      if (eng === 'feed') return false;
      let r = await run(WINPS, eng === 'burnttoast' ? BURNT_SCRIPT : WINRT_SCRIPT, { payload, timeoutMs: 20_000 });
      if ((r.code !== 0 || !/ok/.test(r.stdout)) && eng === 'burnttoast') { engine = 'winrt'; r = await run(WINPS, WINRT_SCRIPT, { payload, timeoutMs: 20_000 }); }
      if (r.code !== 0 || !/ok/.test(r.stdout)) {
        lastError = `code ${r.code}`;
        if (engine === 'winrt' && !ov.engine) engine = 'feed'; // 降级:托盘气泡兜底
        ctx.log?.(`toast failed (${lastError}); engine=${engine}`);
        return false;
      }
      sent++;
      return true;
    },
  };
  return ch;
}
