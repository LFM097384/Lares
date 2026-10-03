/// AI 语音助手成员(docs/ai-voice-bot.md):服务器把它当一个成员放进房间,
/// userId 以 `u_ai_` 开头。它不是人 —— 不算进「几个人在」,也没有「随时聊 / 在忙」。
library;

import 'models.dart';

/// 内置 AI 语音助手插件的 id。
const String kAiVoicePluginId = 'lares.ai-voice';

/// AI 成员的 userId 前缀(与 server/src/ai_voice_supervisor.js 的 AI_USER_PREFIX 一致)。
const String kAiUserPrefix = 'u_ai_';

bool isAiMemberId(String id) => id.startsWith(kAiUserPrefix);

/// 房里的真人数(不算 AI 助手)。
int humanMemberCount(Iterable<Member> members) =>
    members.where((m) => !isAiMemberId(m.userId)).length;
