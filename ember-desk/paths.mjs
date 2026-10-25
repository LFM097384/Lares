// ember-desk · 状态目录与仓库内路径。状态目录 = $EMBER_DESK_HOME(测试用临时目录)否则 %APPDATA%\ember-desk\。
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

export const VERSION = '0.1.0';
export const NAME = '炉灵';
export const HERE = path.dirname(fileURLToPath(import.meta.url));
export const REPO = path.join(HERE, '..');
export const JITSI_ENTRY = path.join(REPO, 'ember-jitsi', 'index.mjs');
export const ZOOM_ENTRY = path.join(REPO, 'ember-zoom', 'index.mjs');
export const DAEMON_ENTRY = path.join(HERE, 'daemon.mjs');

export function stateDir(env = process.env) {
  const o = String(env.EMBER_DESK_HOME ?? '').trim();
  if (o) return path.resolve(o);
  const appData = env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
  return path.join(appData, 'ember-desk');
}

export function files(dir) {
  return {
    dir,
    config: path.join(dir, 'config.json'),
    token: path.join(dir, 'token'),
    state: path.join(dir, 'state.json'),
    lock: path.join(dir, 'daemon.lock'),
    secrets: path.join(dir, 'secrets.dpapi.json'),
    feed: path.join(dir, 'feed.jsonl'),
    notes: path.join(dir, 'notes'),
    log: path.join(dir, 'daemon.log'),
  };
}
