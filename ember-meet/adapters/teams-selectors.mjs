// ember-meet · Microsoft Teams 网页版 DOM 选择器(只放常量,不放逻辑)。
// **这是最脆的一层**:微软改版就会失效。改这里、跑 test/ 里的夹具测试、再按 LIVE-TEST.md 真会验证。
// 来源:Teams 网页版的 data-tid 属性族(比 Fluent 的哈希 class 稳定),参考了开源项目 Vexa
// (github.com/Vexa-ai/vexa,Apache-2.0)services/vexa-bot/core/src/platforms/msteams/selectors.ts
// 与 teams-capture/src/msteams-captions.ts、teams-chat.ts 里公开记录的选择器;中英文文案两套都列。
// 2026-11 在真 Teams(teams.live.com 免费版,中文界面,一个不存在的会议号,**没有点加入**)上核对过:
// 启动页 joinOnWeb、名字输入框 prejoin-display-name-input、摄像头 / 麦克风开关 toggle-video / toggle-mute
// (input role=switch,checked 表示开,点一下变关)、立即加入 prejoin-join-button。会中(大厅、字幕、聊天、挂断)的选择器**没有**真会核对。

/// 启动页「你想怎么加入 Teams 会议?」→ 在本浏览器继续
export const LAUNCHER_WEB = [
  'button[data-tid="joinOnWeb"]',
  '[data-tid="joinOnWeb"]',
  'button:has-text("Continue on this browser")',
  'a:has-text("Continue on this browser")',
  'button:has-text("Join on the web instead")',
  'a:has-text("Join on the web instead")',
  'button:has-text("在此浏览器上继续")',
  'button:has-text("在此浏览器中继续")',
  'button:has-text("改为在网页上加入")',
];

/// 浏览器 / 系统权限被拒时 Teams 弹的「确定不要音频或视频吗?」
export const CONTINUE_WITHOUT_MEDIA = [
  'button:has-text("Continue without audio or video")',
  'button[aria-label*="Continue without audio"]',
  'button:has-text("在没有音频或视频的情况下继续")',
  'button:has-text("不使用音频或视频继续")',
];

/// 预加入页:显示名输入框
export const NAME_INPUT = [
  'input[data-tid="prejoin-display-name-input"]',
  'input[placeholder*="Type your name"]',
  'input[placeholder*="name" i]',
  'input[placeholder*="姓名"]',
  'input[placeholder*="名字"]',
  'input[placeholder*="名称"]',
];

/// 预加入页:摄像头 / 麦克风开关(role=switch 或 checkbox;状态看 aria-checked / checked / aria-label)
export const CAMERA_TOGGLE = [
  '[data-tid="toggle-video"]',
  '[data-tid="prejoin-video-toggle"]',
  'input[title*="camera" i]',
  '[role="switch"][aria-label*="camera" i]',
  '[role="switch"][aria-label*="video" i]',
  '[role="switch"][aria-label*="摄像头"]',
  'button[aria-label*="Turn off camera"]',
  'button[aria-label*="Turn camera off"]',
];
export const MIC_TOGGLE = [
  '[data-tid="toggle-mute"]',
  '[data-tid="prejoin-audio-toggle"]',
  'input[title*="microphone" i]',
  '[role="switch"][aria-label*="microphone" i]',
  '[role="switch"][aria-label*="麦克风"]',
  'button[aria-label*="Mute microphone"]',
  'button[aria-label*="Unmute microphone"]',
];

/// 预加入页:「立即加入」
export const JOIN_BUTTON = [
  'button[data-tid="prejoin-join-button"]',
  'button#prejoin-join-button',
  'button:has-text("Join now")',
  'button:has-text("立即加入")',
];

/// 大厅(等主持人放行)
export const LOBBY_TEXT = [
  'text=/Someone (?:in the meeting )?(?:will|should) let you in/i',
  'text=/Waiting for someone to let you in/i',
  "text=/When the meeting starts, we'll let people know you're waiting/i",
  'text=/You\'re in the lobby/i',
  'text=/会议中的某人.{0,6}(?:很快|稍后|马上).{0,4}让你进入/',
  'text=/(?:有人|某人).{0,8}让你进入/',
  'text=/正在等待.{0,8}(?:允许|让你)/',
  '[data-tid="lobby-screen"]',
];

/// 被拒 / 会议已结束 / 被移出
export const DENIED_TEXT = [
  'text=/Sorry, but you were denied access/i',
  'text=/you were denied/i',
  'text=/Your request to join was declined/i',
  'text=/(?:你|您)的加入请求被拒绝/',
  'text=/被拒绝/',
];
/// 会议号不存在 / 已删除 / 链接错(2026-11 在 teams.live.com 中文界面用不存在的会议号实测到第二条)
export const NOT_FOUND_TEXT = [
  'text=/We couldn.t find (?:this|the) meeting/i',
  'text=/找不到此会议/',
  'text=/This meeting (?:may have ended|is no longer available)/i',
];
export const ENDED_TEXT = [
  'text=/The meeting has ended/i',
  'text=/You(?:\'ve| have) been removed from (?:this|the) meeting/i',
  'text=/Someone removed you from the meeting/i',
  'text=/会议已结束/',
  'text=/你已被(?:从会议中)?移除/',
  '[data-tid="post-call-screen"]',
];

/// 进会后才有的东西:挂断按钮
export const HANGUP = [
  'button#hangup-button',
  'button[data-tid="hangup-main-btn"]',
  'button[data-tid="call-hangup"]',
  'button[aria-label="Leave"]',
  'button[aria-label^="Leave"]',
  'button[aria-label="离开"]',
  'button[aria-label^="离开"]',
];
/// 挂断后的确认菜单(「离开」/「结束会议」;我们只点「离开」)
export const HANGUP_CONFIRM = [
  '[role="menuitem"]:has-text("Leave")',
  '[role="menuitem"]:has-text("离开")',
];

/// 实时字幕:开启路径 = 更多 → 语言和语音 → 打开实时字幕(→ 有时弹「大家在说什么语言?」确认)
export const MORE_BUTTON = [
  'button#callingButtons-showMoreBtn',
  'button[data-tid="more-button"]',
  'button[aria-label="More"]',
  'button[aria-label="More actions"]',
  'button[aria-label="更多"]',
  'button[aria-label="更多操作"]',
];
export const LANGUAGE_MENU = [
  '[role="menuitem"]:has-text("Language and speech")',
  '[role="menuitem"]:has-text("语言和语音")',
];
export const CAPTIONS_ON = [
  '[role="menuitem"]#closed-captions-button',
  '[role="menuitem"][data-tid="closed-captions-button"]',
  '[role="menuitem"]:has-text("Turn on live captions")',
  '[role="menuitem"]:has-text("Show live captions")',
  '[role="menuitem"]:has-text("打开实时字幕")',
  '[role="menuitem"]:has-text("显示实时字幕")',
  '[role="menuitemcheckbox"]:has-text("Live captions")',
  '[role="menuitemcheckbox"]:has-text("实时字幕")',
];
export const CAPTIONS_LANGUAGE_CONFIRM = [
  '[role="dialog"] button:has-text("Confirm")',
  '[role="dialog"] button:has-text("确认")',
];

/// 字幕 DOM:wrapper 下 author 与 closed-caption-text 按文档顺序配对(主持人视图多一层 items-renderer,访客没有)
export const CAPTION = Object.freeze({
  wrapper: '[data-tid="closed-caption-renderer-wrapper"], [data-tid="closed-caption-v2-window-wrapper"], [data-tid="closed-captions-renderer"]',
  author: '[data-tid="author"]',
  text: '[data-tid="closed-caption-text"]',
});

/// 会议聊天
export const CHAT_BUTTON = [
  'button#chat-button',
  'button[data-tid="chat-button"]',
  'button[aria-label="Chat"]',
  'button[aria-label^="Show conversation"]',
  'button[aria-label="聊天"]',
  'button[aria-label^="显示对话"]',
];
export const CHAT = Object.freeze({
  list: '[data-tid="message-pane-list-runway"], [data-tid="chat-pane-list"], [data-tid="chatPaneMessageList"]',
  message: '[data-tid="chat-pane-message"]',
  author: '[data-tid="message-author-name"]',
  body: '[data-tid="messageBodyContent"], [id^="content-"]',
  /// 自己发的消息(Teams 不给作者名;我们另用「刚发过的文字」回声过滤兜底)
  mine: '[data-tid="chat-pane-message-mine"], [data-mine="true"]',
  compose: '[data-tid="ckeditor"], div[role="textbox"][contenteditable="true"], [contenteditable="true"][aria-label*="message" i], [contenteditable="true"][aria-label*="消息"]',
  send: 'button[data-tid="newMessageCommands-send"], button[aria-label="Send"], button[aria-label="发送"]',
});

/// 参会者面板(只在已经打开时读;不主动开,免得把聊天面板挤掉)
export const ROSTER = Object.freeze({
  item: '[data-tid^="participantsInCall-"], [data-tid="roster-participant"]',
  name: '[data-tid="roster-participant-name"], span[title]',
});
