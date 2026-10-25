// ember-desk · 隐藏运行 PowerShell 的小工具。用户文字一律经 env 变量(base64 的 UTF-8 JSON)传入,绝不拼接进命令行。
import { spawn } from 'node:child_process';

export const WINPS = 'powershell.exe'; // Windows PowerShell 5.1:有 WinRT 投影与 System.Speech
export const PWSH = 'pwsh';

export const b64json = (o) => Buffer.from(JSON.stringify(o), 'utf8').toString('base64');

/// 解出 env 里的 base64 JSON 的 PowerShell 片段 → $p
export const PS_DECODE = '$p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:EMBER_DESK_PAYLOAD)) | ConvertFrom-Json';

/**
 * 运行 exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command <script>,payload 经 env EMBER_DESK_PAYLOAD。
 * resolve {code, stdout};永不 reject。
 */
export function runPs(exe, script, { payload, timeoutMs = 30_000, spawnImpl = spawn } = {}) {
  return new Promise((resolve) => {
    let out = '';
    let child;
    const env = { ...process.env };
    if (payload !== undefined) env.EMBER_DESK_PAYLOAD = b64json(payload);
    try {
      child = spawnImpl(exe, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script], { windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'], env });
    } catch (e) { return resolve({ code: -1, stdout: '', error: e.message }); }
    const t = setTimeout(() => { try { child.kill(); } catch { /* */ } }, timeoutMs);
    t.unref?.();
    child.stdout?.on('data', (d) => { out += d; });
    child.on('error', (e) => { clearTimeout(t); resolve({ code: -1, stdout: out, error: e.message }); });
    child.on('close', (code) => { clearTimeout(t); resolve({ code, stdout: out }); });
  });
}
