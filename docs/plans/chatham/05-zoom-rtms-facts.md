# Zoom RTMS 协议事实表（2026-10 核对）

来源均为 Zoom 官方文档 / 官方 GitHub。标 UNCONFIRMED 者未能核实。键：[DT] https://developers.zoom.us/docs/rtms/data-types/ · [UE] https://developers.zoom.us/docs/rtms/event-reference/universal-events/ · [SE] https://developers.zoom.us/docs/rtms/event-reference/session-events/ · [MP] https://developers.zoom.us/docs/rtms/media-parameter-definition/ · [QWS] https://developers.zoom.us/docs/rtms/meetings/quickstart-websockets/ · [WH] https://developers.zoom.us/docs/api/webhooks/ · [WR] https://developers.zoom.us/docs/api/rtms/events/ · [TS] https://developers.zoom.us/docs/rtms/troubleshooting/ · [AF] https://developers.zoom.us/docs/rtms/meetings/add-features/ · [D.TS] https://github.com/zoom/rtms/blob/main/rtms.d.ts

## 1. Webhook
- URL 校验：请求 `{"payload":{"plainToken":"…"},"event_ts":…,"event":"endpoint.url_validation"}`；响应 `{"plainToken", "encryptedToken": hex(HMAC-SHA256(key=webhook secret token, msg=plainToken))}`，3 秒内 200/204。[WH]
- 签名：`x-zm-signature` = `"v0=" + hex(HMAC-SHA256(secretToken, "v0:" + x-zm-request-timestamp + ":" + rawBody))`，时间戳为秒。[WH]
- `meeting.rtms_started` payload：`account_id, is_original_host, meeting_id(int64), meeting_uuid, operator_id, rtms_stream_id, server_urls`（字符串，多个以逗号分隔）。[WR]
- `meeting.rtms_stopped` payload：`meeting_uuid, rtms_stream_id, stop_reason(int)`。另有 `meeting.rtms_interrupted`。webinar 用 `webinar.*` / `webinar_uuid`。[WR]

## 2. 信令 WebSocket
- msg_type（整数）：1 SIGNALING_HAND_SHAKE_REQ · 2 _RESP · 3 DATA_HAND_SHAKE_REQ · 4 _RESP · 5 EVENT_SUBSCRIPTION · 6 EVENT_UPDATE · 7 CLIENT_READY_ACK · 8 STREAM_STATE_UPDATE · 9 SESSION_STATE_UPDATE · 10/11 SESSION_STATE_REQ/RESP · 12/13 KEEP_ALIVE_REQ/RESP · 14 MEDIA_DATA_AUDIO · 15 VIDEO · 16 SHARE · 17 TRANSCRIPT · 18 CHAT · 19/20 STREAM_STATE_REQ/RESP · 21/22 STREAM_CLOSE_REQ/RESP · 23–27 META_DATA_* · 28/29 VIDEO_SUBSCRIPTION_REQ/RESP。[DT]
- 签名：`hex(HMAC-SHA256(clientSecret, clientId + "," + meeting_uuid + "," + rtms_stream_id))`。[QWS]
- 请求：`{msg_type:1, protocol_version:1, sequence, meeting_uuid, rtms_stream_id, signature, buffer_data?}`。[UE]
- 响应：`{msg_type:2, protocol_version:1, sequence, status_code:0, reason:"", media_server:{server_urls:{audio,video,transcript,all}}}`。status_code 0=OK, 1 无效消息类型, 2 无效 stream id, 3 签名无效, 8 重复信令请求, 9–13 媒体类型不支持。[UE][DT]

## 3. 媒体 WebSocket
- media_type 位掩码：audio 1 · video 2 · deskshare 4 · transcript 8 · chat 16 · all 32。[DT]
- 请求：`{msg_type:3, protocol_version, sequence, meeting_uuid, rtms_stream_id, signature, media_type, media_params?}`。[UE]
- media_params：audio `{content_type:2, sample_rate:1(16k), channel:1, codec:1(L16), data_opt:1(MIXED)|2(MULTI), send_rate:20}`；transcript `{content_type:5, src_language, enable_lid}`。sample_rate 0=8k 1=16k 2=32k 3=48k。[MP]
- 响应：`{msg_type:4, status_code, reason, sequence, payload_encrypted, media_params}`（字段名文档自相矛盾，亦见 `payload_encryption`）。
- 收到 4 且 status 0 后，在**信令**连接上发 `{msg_type:7, rtms_stream_id}`。[UE]

## 4. 数据
- 转写：`{msg_type:17, content:{user_id, user_name, start_time, end_time, timestamp, language, data}}`；未记载 interim/final 标志（UNCONFIRMED）。[UE]
- 音频：`{msg_type:14, content:{user_id, user_name, data(base64 L16 16k mono 20ms), length, timestamp}}`；MIXED 时 user_id=0。[UE]
- 聊天：`{msg_type:18, content:{timestamp, data, chat_session, operation_type, message_id, sender:{user_id,user_name}, files}}`（仅公开聊天）。[UE]
- 事件类型：1 FIRST_PACKET_TIMESTAMP · 2 ACTIVE_SPEAKER_CHANGE · 3 PARTICIPANT_JOIN · 4 PARTICIPANT_LEAVE · 5/6 SHARING_START/STOP · 7 MEDIA_CONNECTION_INTERRUPTED · 8/9 VIDEO_ON/OFF。[DT]
- 订阅：信令上发 `{msg_type:5, events:[{event_type:3, subscribe:true}, …]}`，无响应。[UE]
- 推送：`{msg_type:6, event:{event_type, timestamp, user_id, user_name}}`；入/离会为 `participants:[{user_id, user_name?}]`。[SE]
- `{msg_type:8, state, reason, timestamp}`；`{msg_type:9, state, stop_reason, timestamp}`。session state 0 INACTIVE 1 INITIALIZE 2 STARTED 3 PAUSED 4 RESUMED 5 STOPPED；stream state 0 INACTIVE 1 ACTIVE 2 INTERRUPTED 3 TERMINATING 4 TERMINATED 5 PAUSED 6 RESUMED。[DT]
- STOP_BC_*：1 HOST_TRIGGERED 2 USER_TRIGGERED 3 USER_LEFT 4 USER_EJECTED 5 HOST_DISABLED_APP 6 MEETING_ENDED 7 STREAM_CANCELED 8 STREAM_REVOKED 9 ALL_APPS_DISABLED 10 INTERNAL_EXCEPTION 11 CONNECTION_TIMEOUT … 24 KEEP_ALIVE_TIMEOUT 25 MANUAL_API_TRIGGERED 26 STREAMING_NOT_SUPPORTED。[DT]

## 5. 心跳
- **服务端**每 10 s 在信令与媒体两条连接上发 `{msg_type:12, timestamp}`，客户端回 `{msg_type:13, timestamp}`（同值）；漏 3 次即中断，等待重连约 60 s，超时 stop_reason 24。客户端 65 s 未收到心跳应重做信令握手；重连退避 3 s 起倍增至 30 s。[UE]

## 6. 启动 RTMS
- Zoom Apps SDK：`zoomSdk.startRTMS()` / `stopRTMS()` / `getRTMSStatus()` / `onRTMSStatusChange`（客户端 6.4.10+，inMeeting）；需在 Surface → Zoom App SDK 勾选 StartRTMS/StopRTMS。[AF]
- REST：`PATCH /v2/live_meetings/{meetingId}/rtms_app/status`，`{action:"start"|"stop", settings:{client_id}}`，scope `meeting:update:participant_rtms_app_status`。[AF]
- 媒体 scope：`meeting:read:meeting_transcript`、`meeting:read:meeting_audio`（另有 video / chat）；RTMS scope 不可选。[AF]
- `zoomSdk.sendMessageToChat(options)`（6.2.5+）可向会议聊天发消息。

## 7. 账号条件
- 需要 **Zoom Developer Pack**；Basic 免费账号不支持（webhook 不触发，API 报 2310）；Pro/Business/Enterprise 也须 Developer Pack。有免费试用（5 路并发）。[TS]
- App 类型：**General app（user-managed）**；内部使用无需 Marketplace 审核。[AF]

## 8. SDK
- `@zoom/rtms` v1.1.0：Node ≥22 原生插件，仅 linux-x64 / darwin-arm64（无 Windows）。纯 `ws` 实现有官方 quickstart 背书。[QWS]
