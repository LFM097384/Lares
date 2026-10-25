// 会议通道 · Lares:桌面端不启动。ember-lares 由 Lares 服务器(server/src/anonym_supervisor.js)按圈拉起。
export const DETAIL = '由 Lares 服务器(server/src/anonym_supervisor.js)按圈拉起,不由桌面端启动';

export default function meetingLares() {
  return {
    id: 'meeting-lares',
    kind: 'meeting',
    name: 'Lares 圈',
    describe: () => DETAIL,
    configured: () => false,
    async start() { throw Object.assign(new Error(DETAIL), { status: 400 }); },
    async stop() {},
    status: () => ({ running: false, detail: DETAIL }),
    prepareJoin() {
      throw Object.assign(new Error(`这是 Lares 圈的链接:炉灵${DETAIL}。请在 Lares 应用里由圈主开启炉灵。`), { status: 400, code: 'lares_server_spawned' });
    },
  };
}
