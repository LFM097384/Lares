// 输出通道 · 会议聊天:如实说明。
// 会议聊天由会议插件自己负责(ember-jitsi 在聊天里发规则公告、草稿、放行纪要;ember-zoom 经侧边栏)。
// 插件 CLI 的 stdin 只认 {"cmd":"stop"},不支持从桌面端往会议聊天发任意文字 —— 所以这里 send() 不发任何东西,只报告不支持。
// status 反映当前是否有一个在会中的会话(聊天由插件在用)。
export default function outputMeetingChat(ctx) {
  const sess = () => ctx.session?.();
  return {
    id: 'meeting-chat',
    kind: 'output',
    name: '会议聊天',
    describe: () => '会议聊天由会议插件自己发(规则公告、放行纪要);桌面端不能往会议聊天发任意文字',
    configured: () => true,
    async start() {},
    async stop() {},
    status() {
      const s = sess()?.session;
      const live = Boolean(s && s.state === 'in-meeting');
      return { running: false, detail: live ? `会议中(${s.room ?? s.adapter}):聊天由插件负责,桌面端不转发文字` : '无活动会议' , extra: { live } };
    },
    async send() {
      return { ok: false, reason: 'unsupported: 会议插件 CLI 不支持从桌面端发聊天文字' };
    },
  };
}
