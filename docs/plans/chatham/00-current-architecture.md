# Lares — Current Architecture Map (ground truth for Chatham House Rule mode)

> **Status:** factual map of the codebase at `b61e016` (2026-10-06); also notes the untracked working-tree items listed below.
>
> **Purpose:** baseline for designing "Chatham House Rule mode", which has three goals: (a) AI embedded in the conversation leaves no trace; (b) real-time transcription works over P2P without a server; (c) any AI that can publish to non-participants receives only de-identified information.
>
> **Method:** I read the code and docs, and every claim cites `path:line`. ⚠️ marks claims that are inferred or not verified end to end.
>
> Three untracked items are on disk but not in git — **none is part of the shipped architecture**: `app/lib/src/chatham_preview/` (a UI mock); `server/chatham/` (an eval harness plus the L3/L4 libs); `.tmp-win/captions/phase0/` (the ASR A/B report).

---

## 1. Topology

### 1.1 Planes

| Plane | Process / port | Role | Cite |
|---|---|---|---|
| Signaling | Node `server/src/index.js`, WS on `:8787` (`/` or `/ws`) + HTTP | auth, presence, knock, kick, feature flags, LiveKit token mint, transcript archive/relay, bot REST/SSE, plugins, focus, push | `server/src/index.js:35`, `:2356-2366` |
| SFU | LiveKit `v1.13.6`; 7880 WS/Twirp (behind Caddy), 7881/tcp, 7882/udp mux | all room media + data channel (chat, captions, AI state) | `deploy/systemd/livekit.yaml:3,15-22`; `deploy/docker-compose.yml:41,50-54` |
| Reverse proxy | Caddy, `${LARES_HTTPS_PORT:-8444}` | TLS; `/ws`,`/api/*`,`/notes*`,`/health` → `lares-server:8787`; `/rtc*`,`/twirp*`, catch-all → `livekit:7880` | `deploy/caddy/routes.caddyfile:9-50`; `deploy/docker-compose.yml:195-207` |
| Cloud ASR/TTS | Alibaba DashScope (Beijing) | client captions ASR; AI bot ASR + TTS (+ LLM fallback) | `server/src/index.js:860-870`; `server/bots/voice-agent/providers/dashscope.mjs:8,17,148` |
| Cloud LLM | DeepSeek (OpenAI-compatible) or DashScope `qwen-flash` | AI voice bot replies | `server/bots/voice-agent/providers/openai_compat.mjs:3-7,129-152` |
| AI voice bot | Node child process per circle, same host; loopback WS + LiveKit client | see §4 | `server/src/ai_voice_supervisor.js:112-116`; `server/src/index.js:2216-2217` |

LiveKit:
- Config: `max_participants 20`, audio/opus only, `empty_timeout 300` (`deploy/systemd/livekit.yaml:27-41`; compose `:237-250`); **TURN is disabled** (same lines as above).
- `lares-server` is not published to the outside, only `expose: 8787` on the internal network (`deploy/docker-compose.yml:133-135`); the signaling server reaches the LiveKit admin API at `http://livekit:7880` (`:79-81`).

Caddy: TLS modes `dns|http|file|selfsigned` (`deploy/caddy/Caddyfile.*`); log level WARN (`routes.caddyfile:46-49`).

### 1.2 Signaling server

**Auth.** `LARES_AUTH_MODE` takes `none` (default) | `token` | `circle` | `token,circle` (`server/src/index.js:41-48,73,86-89`).
- Challenge–response with a single-use nonce, 60 s TTL (`:121-147`, `:1202-1204`). **Token mode:** `HMAC(LARES_AUTH_TOKEN, nonce:userId)` (`:248,262-266`). **Circle v2:** `HMAC(verifier, nonce:userId:circleId)`, where `verifier = Argon2id(passcode,"lares-auth-v2:"+circleId)` (`:271-274,294`; `app/lib/src/auth/auth_verifier.dart:35-45`).
- **Registered circles:** the server stores only `{verifier, ownerHash, createdAt}`, in `circles.json` with mode 0600; accepts only v2 (`:289-312,405-417,446-458`).
- **Env circles** (`LARES_CIRCLE_PASSCODES`) and the site-wide fallback passcode are held **in plaintext in the server env** (`:278-287,315-323`). ⚠️ Inference: the operator can therefore derive their E2EE keys.
- **Auth-failure limit:** more than 10 failures from one IP within 5 min triggers a 5-minute block (close 4429) (`:149-153,1194`).

**In-memory state:** `circles` maps userId → `{name,emoji,bio,status,platform,latencyMs,loc,rec,devices}` (`:358,1933-1943`); also `lobby`, `available`, `pendingKnocks` (`:368,678,693`).

**WS messages.** The main switch (`:1222-1882`) handles: `hello, join, available, unavailable, latency, p2p_signal, reach, knock_allow, kick, loc, loc_off, rec_start/stop/ping, knock_mode_set, circle_passcode_set, circle_e2ee_set, circle_delete, leave, push_*, token_prefetch, profile, profile_set, status, cap_token, ping`.

Other messages go to delegated modules (`:1214-1219`): `transcript_ws.js` handles `circle_transcript_set`, `transcript_append/get/clear/relay/relay_ack` and `bot_token_create/list/revoke` (`server/src/transcript_ws.js:100-251`); `features.js` handles `circle_features_set` and `circle_purpose_apply/export` (`server/src/features.js:247-249`); `plugins.js` handles `plugin_*` (`server/src/plugins.js:727-750`); `focus.js` handles `focus_*` (`server/src/focus.js:688-713`).

**LiveKit token.** Minted by `mintLiveKitToken` (`:822-833`): identity = userId, name = display name, room = circleId; TTL 2 h; grants `roomJoin, canPublish, canSubscribe, canPublishData`; issued on every `join` (`:1956-1967`). **So LiveKit always sees circleIds, userIds and display names.**

**HTTP endpoints:** `/api/v1*`: bot REST + SSE, see §3.5 (`:2291-2295`); `/health`: hides counts when auth is on (`:2297-2305`); `GET/POST /notes` and `DELETE /notes/:id`: voice notes, Bearer auth (`:2308-2348`).

**Server-injected data.** `livekit_senddata.js` uses Twirp `RoomService/SendData` with a 5-minute room-admin JWT, on topics `lares.chat` and `lares.cap` (`server/src/livekit_senddata.js:13-14,42-80`). Clients trust frames that have no participant as coming from the server or a bot (`:3-6`; `app/lib/src/chat/chat_envelope.dart:253-268`).

**Bot speak.** The bot joins as `bot:<id>` with `canPublish:true, canSubscribe:false, canPublishData:false` and plays a WAV of up to 60 s (`server/src/bot_speak.js:1-9,97-133`).

### 1.3 P2P mode (`p2p` feature)

Both paths use raw `flutter_webrtc 1.6.0`; LiveKit has no P2P mode (`app/pubspec.yaml:30-37`).

**Path 1: 1:1 manual connect code. This one is truly serverless.**
- Peers exchange an offer code `LARES-O1:` and an answer code `LARES-A1:` (`app/lib/src/p2p/connect_code.dart:13-16,38-43,94-102`), each about 688 B of gzip+base64url SDP, small enough for a QR code.
- The app gathers all ICE candidates before showing the code, with an 8 s timeout (`app/lib/src/p2p/p2p_session.dart:155-168,247-252`). Audio only (`p2p_session.dart:123-124`).
- No default STUN/TURN; users can set them in prefs (`app/lib/src/p2p/ice_store.dart:16-22`); without them it only works on the same LAN (`app/lib/src/ui/developer_section.dart:100`).
- Media is protected only by WebRTC DTLS-SRTP; there is no Lares-level key.

**Path 2: mesh over server signaling.**
- A star: the host connects to everyone, everyone else only to the host (`app/lib/src/p2p/p2p_mesh.dart:21-27,127-174`). **`kMeshMaxPeers = 4`** (`p2p_mesh.dart:50,111`).
- Host election uses `electHost` (`app/lib/src/p2p/host_election.dart:62-117`): scores latency, with −150 ms for desktop; 300 ms hysteresis.
- SDP travels over the WS `p2p_signal` message (`server/src/index.js:1401-1434`; tests `server/test/p2p_signal.mjs:100-202`). The server checks the session, the `p2p` feature, size (≤8192 chars) and that both peers are in the same circle and room, then forwards the payload without inspecting it. **The SDP is not encrypted, so the server can read the ICE candidates, which contain participants' IP addresses.**
- The mesh requires being `inRoom` first, i.e. already joined to LiveKit, and is not started automatically (`app/lib/main.dart:168-178,204-207`).

**Hard facts:**
- **There is no RTCDataChannel anywhere in `app/lib`;** a grep finds zero hits. P2P therefore carries no chat, images, E2EE, recording or captions (`p2p_session.dart:9-11`; `developer_section.dart:76-78`).
- **The host does not forward audio.** The only media call is `pc.addTrack(t, mic)` (`p2p_session.dart:243`); no remote-track handling or re-publication in `lib/src/p2p/`. ⚠️ This comes from reading the code, not running it. In a 3–4 peer star, non-host peers probably hear only the host.
- **flutter_webrtc 1.6.0 exposes no PCM to Dart** (`p2p_mesh.dart:18-19`). On-device ASR over P2P would need a separate mic tap.
- **The `p2p` flag:** new circles default to `false`; legacy circles without a features object resolve to `true` (`server/src/features.js:12-16,26-34`); the client's legacy default is all-on (`app/lib/src/state/circle_features.dart:34-48`); enforced only at `p2p_signal` (`index.js:1414`).
- The P2P UI lives only in the developer section, reached through an easter egg (`developer_section.dart:75-93`; `app/lib/src/ui/p2p_screen.dart:34-45,104-116`). Chat transport is hard-bound to the LiveKit room (`app/lib/src/chat/session_chat_transport.dart:35,57-80`).

### 1.4 What the server sees: plaintext vs E2EE

| Data | Non-E2EE circle | E2EE circle |
|---|---|---|
| Audio frames | SFU forwards SRTP (SFU terminates DTLS ⚠️) | LiveKit frame cryptor; opaque to SFU |
| Data channel (`lares.chat`, `lares.cap`, `lares.ai`) | plaintext to SFU | encrypted (`encryption:` enables DC E2EE) |
| Transcript archive | **plaintext JSONL on server** | AES-GCM blobs; server sees sender, ts, size, member list |
| Caption audio | user's own mic → DashScope | same, only with `e2eeOptIn` |
| Presence/profile, membership, join/leave, status, platform, latency | plaintext | **plaintext** |
| Location (`loc`) | relayed plaintext, not persisted | **plaintext** (`index.js:1521-1539`) |
| P2P SDP/ICE (IPs) | plaintext relay | **plaintext** |
| Voice notes | **plaintext audio on disk** | **plaintext audio on disk**, no E2EE check (`index.js:2313-2329`; `app/lib/src/state/voice_notes.dart:155-165`) |
| Plugin shared state, focus stats, push subscriptions | plaintext | **plaintext** (`docs/plugin-api.md:284`) |
| Recording state (`member_rec`) | plaintext | plaintext |

---

## 2. E2EE

### 2.1 Key derivation (client)

**Live path, v2** (`app/lib/src/e2ee/e2ee_key.dart:108-123`):
- **Parameters:** Argon2id v1.3, 64 MiB memory, t=3, p=1, 32-byte output, with `passcode.codeUnits` as the input (`:78-81,113-121`).
- **Salt:** the first 16 bytes of `sha256("lares-e2ee-v2:"+circleId)` (`:130-135`); deterministic because there is no channel to distribute a salt (`:95-98`).
- **Output:** 64 lowercase hex characters, used as the LiveKit shared key (`:101-104,122`). Runs in an isolate (`:149-160`).
- **The parameters are frozen.** Changing them would break every existing circle (`:57-61`).

**Legacy v1:** `HMAC-SHA256(passcode,"lares-e2ee-v1:"+circleId)` (`:28,43-47`). I found no caller in `app/lib`.

**Auth verifier vs media key.** The auth verifier uses a different salt (`"lares-auth-v2:"`), so the verifier the server holds cannot produce the media key (`app/lib/src/auth/auth_verifier.dart:9-13`; `server/src/index.js:495-508`). **Caching.** The key is cached in memory per passcode and never written to disk (`app/lib/src/e2ee/e2ee_controller.dart:139,150-151`; `app/lib/src/e2ee/e2ee_store.dart:12-13`). **Wiring.** `E2EEOptions.sharedKey(key)` is passed to `RoomOptions(encryption:)`, which also encrypts the data channel (`e2ee_controller.dart:35-43`; `app/lib/src/rtc/livekit_rtc_service.dart:224-233`).

**Standalone bots** derive the same key (`server/bots/voice-agent/room.mjs:20-23,95-99`; `server/tool/lares_bot.mjs`). ⚠️ Node `argon2id({password:string})` likely hashes UTF-8 bytes, while the app hashes `codeUnits`, so non-ASCII passcodes may produce mismatched keys.

### 2.2 Distribution, passcode (口令), owner key

**No in-band key distribution.** Every member derives the key from the passcode, shared out of band. Invite links exclude the passcode by default; including it is opt-in, and the app then warns 「口令就是解密密钥」 ("the passcode is the decryption key") (`app/lib/src/ui/home_screen.dart:443`; `app/lib/l10n/app_zh.arb:256-262`).

**Default passcode:** 4 BIP39 words, about 44 bits, with a minimum of 8 characters (`app/lib/src/auth/circle_identity.dart:10,51-65`).

**Vault storage:** passcode stored under `lares.secret.passcode.<cid>` in `flutter_secure_storage`; on iOS it uses `first_unlock_this_device`, so it is not backed up to iCloud; if secure storage is unavailable, it falls back to an in-memory vault that does not persist (`app/lib/src/net/secret_vault.dart:46-54,73-98`).

**Owner key:**
- 32 random bytes as hex, generated on the client (`circle_identity.dart:36-49`) and vaulted as `lares.secret.owner.<cid>` (`secret_vault.dart:102-103`). The server stores only `sha256` of it (`index.js:303-306,411-412`).
- The plaintext owner key is sent with every owner operation (`index.js:481-486,803-808`). **The owner key plays no part in E2EE key derivation.**

### 2.3 What the `e2ee` flag does

**Setting and propagation:** `circleSettings[cid].e2ee` is owner-only, set via `circle_e2ee_set` (`index.js:1675-1687`); pushed to clients as `circleInfo.e2ee ∈ {true,false,null}` (`:570-572`); on `null` the client falls back to its local `E2EEStore` toggle (`app/lib/src/state/room_controller.dart:308`; `e2ee_controller.dart:105-122`).

**Client behaviour on failure:** when encryption cannot be applied, the client shows a loud downgrade (`platformUnsupported|noPasscode|failed`) rather than refusing to join (`app/lib/src/e2ee/e2ee_status.dart:20-33,105-114`). **The server cannot verify that media is actually encrypted.**

**Server-side effects of `e2ee===true`:**
- Plaintext transcripts are refused; only the relay is allowed (`server/src/transcript_ws.js:118,146,181`). Bot REST content endpoints return 409 (`server/src/bot_api.js:153-155`). The hosted AI voice bot is refused (`server/src/ai_voice_supervisor.js:80`).
- `cap_token` requires `e2eeOptIn` (`index.js:1866`). Push content is redacted (`index.js:1072-1078`; `server/src/push_triggers.js:96-98`).
- ⚠️ All of these gates test `=== true`. A circle whose policy is `null` (legacy/env) but whose members encrypt locally is treated as **non-E2EE** by bot REST and transcripts.

### 2.4 What is encrypted

| Item | Encrypted? | Cite |
|---|---|---|
| LiveKit audio frames | yes (E2EE circles) | `e2ee_controller.dart:24-43` |
| Data channel: chat `lares.chat`, captions `lares.cap`, AI state `lares.ai` | yes (E2EE circles); envelopes are plain JSON inside | `livekit_rtc_service.dart:226-228`; `app/lib/src/captions/caption_protocol.dart:1-10` |
| Transcript archive, E2EE | HKDF-SHA256(ikm=circle key, salt=circleId, info=`lares-transcript-v1`) → AES-256-GCM, 12 B nonce, AAD=circleId; blob `base64(0x01‖nonce‖ct‖tag)`; plaintext `{id,uid,name,text,startedAt,ts}` | `app/lib/src/transcript/transcript_crypto.dart:1-10,56-63,95-139` |
| Transcript archive, non-E2EE | **no** — server JSONL | `server/src/transcripts.js:5-6` |
| Voice notes | **no** | §1.4 |
| Signaling WS | TLS only | — |

### 2.5 Key rotation

**There is no key versioning, ratchet or rekey protocol.** The design doc lists rotation as future work: 「E2EE 密钥有代次 `{v:1,key}`」 ("E2EE keys carry a generation `{v:1,key}`") and 「轮换后面加」 ("rotation comes later") (`docs/plans/identity-and-roles.md:150-162,235,249`).

**Kick** is signaling-only, documented as 「非封禁,可再进」 ("not a ban; can rejoin") (`index.js:1490-1519,600-623`); it adds a best-effort LiveKit `removeParticipant`. **The key does not change, and the kicked user still knows the passcode.**

**The real eviction mechanism is `circle_passcode_set`** (`index.js:1640-1673`): owner submits a new verifier → server sets `rekeyedAt` and drops push subscriptions → every other session receives `circle_rekeyed`, is closed with code 4401, and is evicted from media → because the key is derived from the passcode, the E2EE key changes as a side effect → the new passcode is redistributed out of band.

**Limits:** no forward secrecy and no post-compromise security. ⚠️ I did not verify whether old relay blobs and local transcripts remain readable after a rotation.

**`circle_delete`:** keeps a verifier tombstone forever; deletes the transcript archive, the relay and bot tokens (`index.js:1690-1724`; `transcript_ws.js:85-91`).

### 2.6 `captionsE2eeCloud` opt-in

**Setting:** pref `lares.captionsE2eeCloud`, default **false** (`app/lib/src/state/settings_store.dart:48,71-72,170`); the switch is enabled only when `captionsProvide` is on (`app/lib/src/ui/settings_sheet.dart:314-323`).

**Gate:** `willing = available && provide && (!encrypted || e2eeCloud)` (`app/lib/src/captions/caption_controller.dart:90`).

**Server enforcement:** the client sends `e2eeOptIn = captionsE2eeCloud && circleEncrypted` (`app/lib/main.dart:500-508`); the server refuses `cap_token` without it, but **only when `circleSettings.e2ee===true`** (`index.js:1866`; test `server/test/captions.mjs:248-252`).

**Meaning:** in an E2EE circle, the user agrees that their **own** mic audio goes to Alibaba so others can get captions or an archive. The resulting caption text travels inside the encrypted data channel. The opt-in is not documented anywhere in `docs/`.

---

## 3. Captions and transcript

### 3.1 Speech recognition: each speaker sends their own mic to the cloud

**Capture.** Each client taps **only its own local mic track**, as 16 kHz mono Int16 (`app/lib/src/captions/livekit_caption_session.dart:14-19,92-103`); `app/lib/main.dart:497-499` explains this design. A device runs at most one ASR session at a time (`caption_controller.dart:540-545`). Nobody transcribes another person's audio; the one exception is the AI bot (§4).

**Endpoint.** `wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime`, overridable via `LARES_DASHSCOPE_WS_URL` and `LARES_CAPTIONS_MODEL` (`server/src/index.js:860-870`).

**Session settings.**
- `session.update` sets: text only, PCM 16 kHz, **no language hint**, `server_vad` with threshold 0.2 and silence 800 ms (`app/lib/src/captions/qwen_realtime_stt.dart:343-358`). Audio goes up as base64 chunks of 100 ms / 3200 B, with up to 6 s buffered before connect (`:73-80,191-196`).
- Stopping sends `session.finish` and closes the socket; the rule is "no idle mic channel to the cloud" (`:1-14,204-229`). DashScope closes the session with 1011 at 600 s; the client then reconnects (`:278-281`). Errors log codes only, never text (`:381-384`).

**API key handling.** The server holds the long-term `LARES_DASHSCOPE_API_KEY` and exchanges it for a short-lived `st-` token via `POST /api/v1/tokens?expire_in_seconds=300` (`index.js:900-914`).

**`cap_token` gates**, checked in order (`index.js:1855-1880`): authed → captions configured → in room → feature `captions` or `transcript` on → if the circle is E2EE, `e2eeOptIn===true` → rate limit: 20 per user per hour, 2000 globally per hour, in memory (`:873-889`). The client caches the token until 60 s before expiry (`app/lib/src/captions/caption_wiring.dart:23-101`).

**Platforms.** Not supported on Web, because a browser WebSocket cannot set the `Authorization` header (`app/lib/src/captions/stt_socket.dart:30-36`). **Phase 0 A/B.** Tuning came from it (`qwen_realtime_stt.dart:3,350`); results in §3.6.

### 3.2 The `lares.cap` data topic

**Transport.** LiveKit data channel through the SFU, `reliable:true` (`livekit_caption_session.dart:148-158`); E2EE-encrypted in E2EE circles.

**Messages** (`app/lib/src/captions/caption_protocol.dart:1-19`; `docs/plans/transcript-bot-contract.md:5-12`):

| Message | Meaning |
|---|---|
| `capreq{on}` | "I want captions" |
| `capack{on}` | "I consent to transcribe myself" |
| `cap{id,seq,text,final}` | Caption text, ≤2000 chars |

**Sending.** `cap` is **broadcast to all** (`caption_controller.dart:720-731`), only when there are requesters and `liveCaptions` is on. Partials are throttled to one per 200 ms (`:32`); a filler-only final is sent as an empty final (`:707-709`). `capreq`/`capack` can be targeted with `destinationIdentities` (`livekit_caption_session.dart:151-156`).

**Anti-forgery** (`caption_protocol.dart:109-130`): a participant-less frame carrying `bot` is accepted as `bot:<id>` (server-injected); a participant frame that claims `bot` is dropped.

**Receiving.** The viewer keeps the last 30 lines **in memory only** and clears them on caption-off, leave, or circle exit (`caption_controller.dart:337-342,374-377,394,489-491`). Live captions are never persisted.

### 3.3 Consent: `captionsProvide`, `capack`, archive

**Settings.** `lares.captionsProvide` defaults to **true** (`app/lib/src/state/settings_store.dart:47,68-69,169`), meaning "send my voice to the cloud for whoever asks". `captionsE2eeCloud` defaults to false (§2.6).

**Willingness and consent.** `willingNow = willing && !stoppedForSession && !fatal` (`caption_controller.dart:496`). The banner's "stop" sets a per-session stop that survives reconnects (`app/lib/src/ui/caption_panel.dart:52-98`; `caption_wiring.dart:190-194`).

**When transcription runs** (`caption_controller.dart:520-534`): formula `_needed = (liveCaptions && (remote requested || I want)) || archive`. **Turning on the archive alone makes every willing member transcribe, even with no viewers.** It also needs: in room, not muted, mic published.

**`capack` delivery** (`:379-381,406-409,442-445,498-510`): sent in reply to `capreq`; broadcast when the archive is on; sent to newcomers. Receivers show decliners as "not transcribed" (`:261-271`).

**Enforcement is self-enforcement by the speaker's own client.** The server never sees `capack`. The AI bot honours `capack{on:false}` (`server/bots/voice-agent/pipeline.mjs:403-412`). When an owner enables the archive in an E2EE circle, a warning dialog is shown (`app/lib/src/transcript/transcript_owner_section.dart:47-62,86`).

### 3.4 Transcript archive

**What gets archived.** Only own **finals** while `willingNow` (`caption_controller.dart:711-713`), and only if the circle `isTranscriptOn` (`caption_wiring.dart:166-179`). `RoutingTranscriptSink` picks plaintext vs encrypted per circle; with no encrypted sink, E2EE-circle lines are **dropped, never sent in plaintext** (`main.dart:514-523`; `app/lib/src/captions/transcript_sink.dart:59-85`).

**Non-E2EE: plaintext on the server.**
- Wire message: `transcript_append{circleId,id,text,startedAt}`. Server-side checks (`server/src/transcript_ws.js:24-27,113-138`): authed, in room; not E2EE; transcript on; text 1–2000 chars; rate 2/s, burst 20. `name` is taken from the session (`:127`).
- Storage: `DATA_DIR/transcripts/<enc(cid)>.jsonl`, mode 0600 (`server/src/transcripts.js:5-6,102-135`); line format `{seq,ts,userId,name,id,text,startedAt}`; idempotent on `(userId,id)`.
- Each line is broadcast as WS `transcript_line` (`transcript_ws.js:137`) and emitted to bot SSE plus plugin webhooks (`index.js:2256-2260`; `server/src/plugins.js:313-325`).
- `transcript_get` needs only circle auth, not room presence; pages are 50 by default, 200 max (`transcript_ws.js:141-153`).
- Deletion: **No TTL.** Removed only by owner `transcript_clear` (`transcript_ws.js:156-173`; `transcripts.js:152-166`) or by `circle_delete` (`transcripts.js:311-319`). Turning transcript off leaves existing records readable (`docs/bot-api.md:84`).

**E2EE: ciphertext relay plus local plaintext store.** Encryption is described in §2.4.
- **Sender.** `EncryptedTranscriptSink` calls `relayOwnLine`, then stores locally (`app/lib/src/transcript/transcript_service.dart:1-11,373-392`).
- **Server-side handling of `transcript_relay`.** Checks: in room, E2EE, transcript on, blob ≤8192 chars, rate limited (`transcript_ws.js:176-202`). It queues the blob for **every member who has ever joined**, except the sender and `u_ai_*` (`transcripts.js:248-271`). Queue limits: 5000 items / 30 days per user, in `DATA_DIR/transcript_relay/<cid>.json` (`:11-14,29-30,233-246`). Queues are re-pushed on hello and join (`transcript_ws.js:44-82`).
- **Receiver.** With no key, it does not ack, so the item stays queued; otherwise it decrypts, writes to disk, then acks (`transcript_service.dart:170-216`).
- **Local store** (`app/lib/src/transcript/local_transcript_store.dart:1-6`; `transcript_backend_io.dart:7-18,42-46`): **plaintext JSONL** at `<AppDocuments>/lares_transcripts/<base64url(cid)>.jsonl`; memory only on Web. **No TTL.** Cleared only by a received `transcript_cleared` (`transcript_service.dart:148-151`). **Every past member keeps a plaintext copy.**

### 3.5 Bot API and bot tokens

**Tokens** (`server/src/bot_tokens.js`): format `lrb_` (bot) or `plg_` (plugin) + 43 base64url chars (`:12,59`); stored as unsalted sha256 in `DATA_DIR/bot_tokens.json`, mode 0600 (`:15,18,41-67`); **no expiry**; ≤20 bot tokens per circle (`:11,56`).

**Mint, list, revoke.** Done over WS `bot_token_*` under `ownerGate`: registered circle + `ownerKey` (`server/src/transcript_ws.js:34-41,214-251`). Revoking closes that token's SSE streams immediately (`server/src/bot_api.js:115-119`). Plugin tokens are minted on install/enable and revoked on uninstall (`server/src/plugins.js:461-507,630-644`).

**Auth and scopes.** Auth is `Authorization: Bearer`; one token = one circle (`bot_api.js:129-144`). **`lrb_` tokens have no scopes.** **Plugin manifest permissions are not enforced on REST/SSE**, only on webhook fan-out (`plugins.js:23-36,313-325`; `docs/bot-api.md:201`).

**Endpoints** (`/api/v1`, `bot_api.js:177-347`):

| Endpoint | Behaviour | E2EE |
|---|---|---|
| `GET /circle` | In-room members `{userId,name,status}`, features, flags (`:182-201`) | allowed |
| `GET /plugins` | — | allowed |
| `GET /focus` | Focus snapshot (`:224-226`) | allowed |
| `GET/POST /plugins/state` | Plugin tokens only | allowed |
| `GET /transcript?before&limit` | **Whole plaintext archive reachable** by paging (`:228-237`; `transcripts.js:138-150`) | 409 |
| `GET /events` (SSE) | 4 streams per token, 200 total, keepalive 25 s (`:239-268,78-80`) | allowed |
| `POST /messages` | Sends `lares.chat` via SendData; not stored (`:270-283`) | 409 |
| `POST /captions` | Sends `lares.cap`; a final is **archived** as `bot:<id>` when transcript is on (`:285-314`) | 409 |
| `POST /speak` | WAV ≤60 s; the bot cannot subscribe, so **cannot listen** (`:316-345`; `bot_speak.js:99-100`) | 409 |

**SSE events:** `ready` (member list), `transcript` (identified text), `transcript_cleared`, `join`, `leave`, `presence`, `chat` (bot-sent only), `plugins`, `plugin_state` (to all streams), `focus` (`bot_api.js:260-266,281`; `index.js:1837,1851,1946,1997,2256-2260`; `plugins.js:343,373`; `focus.js:653`). **No per-event permission filter.**

**What bots cannot see.**
- Member chat and live captions travel over LiveKit only, so REST bots never see them (`bot_api.js:4-5`). In E2EE circles the alternative is a passcode-holding member bot (`server/tool/lares_bot.mjs`), which joins as a normal member with full hearing (`docs/bot-api.md:164-184`; `server/tool/README-bot.md:5-10,118-125`).
- Rate limits: general 60 burst at 1/s; posting 10 burst at 1/s; speak 6 burst at 0.1/s (`bot_api.js:81-84`).

### 3.6 On-device ASR: what exists or was evaluated

**sherpa-onnx (2026-09).**
- Chosen as the "首选" (first choice) for recording STT (`docs/research/DECISIONS-2026-09.md:134,137,159`). Model: `sense-voice-zh-en-ja-ko-yue-2024-07-17` + `silero_vad.onnx`.
- The implementation `SherpaSttBackend` is now parked at `app/_disabled/recording_stt/stt_sherpa.dart`: model `model.int8.onnx` is **228 MB**, downloaded at runtime and not bundled (`:36-50`); 2 threads (`:178`); "几秒 + 几百 MB 内存" to load, i.e. a few seconds and a few hundred MB of memory (`:94-96`); **non-streaming** (`supportsStreaming=>false`, `:227-233`); no diarization, speaker identity comes from the per-participant LiveKit track (`:219-225`).
- **Removed** in the cleanup recorded as "-21.4MB" (`HANDOFF.md:403,420`): the native libs (`onnxruntime.dll` 17 MB + `sherpa-onnx-c-api.dll` 4.4 MB) shipped even though recording was off, because tree-shaking does not remove native libs; also an App Store 2.3.1 "hidden feature" risk (`app/_disabled/recording_stt/README.md:9-23`). Restore steps are in `README.md:32-37`.

**Whisper.** Rejected: `whisper.cpp --diarize` is stereo-only; `whisper_dart` is a 404; `whisper_flutter_new` is GPL-3.0, has no Windows build, and is stale (`DECISIONS-2026-09.md:119-126`). Groq whisper-large-v3-turbo remains as a dormant cloud recording backend with a 10 s minimum bill (`app/lib/src/recording/stt_cloud.dart:29-50`).

**Phase 0 ASR A/B** (2026-09-28). The report exists **only in untracked `.tmp-win/captions/phase0/REPORT.md`**; tracked docs contain no numbers. Setup: 25 TTS-synthesized zh/en clips at 16 kHz with noise.

| Engine | CER | Latency |
|---|---|---|
| `qwen3-asr-flash-realtime`, no language hint | **3.0%** | first partial p50 252 ms; end-of-speech→final p50 779 ms / p90 1807 ms |
| same, `zh` hint | 4.4% | — |
| same, `en` hint | 18% | — (translates Chinese) |
| HTTP flash | 3.2% | 2.4–3.1 s |
| **sherpa streaming zipformer** (`small-bilingual-zh-en-2023-02-16`, int8) | **16.8%** (zh 1.0%, mixed 23.5%, en 43.9%) | first partial ~600 ms; final ~1.5 s |

- Verdict: sherpa "只适合离线兜底", i.e. fit only as an offline fallback (REPORT.md:68). **SenseVoice was not in the A/B** ⚠️. Not tested: real human speech, overlapping speakers, sessions over 10 min.

**Current state.** **There is no on-device ASR in shipped code**, and no ASR dependency in `app/pubspec.yaml`. `app/test/captions_live_test.dart` is an opt-in live CER test against Phase 0 clips (the corpus is outside the repo). Direction from `docs/plans/lares-spirit.md:43-45,71-73,104-109`: STT for the "炉灵" spirit should run **bot-side**; the spirit enters only non-E2EE circles; "转写永久保留" (transcripts are kept permanently). This **conflicts** with a no-trace mode.

---

## 4. AI voice bot (`server/bots/voice-agent`)

**Where it runs.** One Node child per circle, spawned by the signaling server on the same host (`server/src/ai_voice_supervisor.js:112-116`; `server/src/index.js:2213-2217`). It connects back over loopback WS and joins LiveKit as a client (`room.mjs:131`). Global cap: `LARES_AI_MAX_PROCESSES=8` (`ai_voice_supervisor.js:17,53,84`).

**Spawn gates**, in order (`ai_voice_supervisor.js:76-86`): plugin `lares.ai-voice` enabled → ≥1 human present → **not E2EE** → DashScope key present → auth material available → capacity left.

**Lifecycle.** Empty room: 20 s grace, then SIGTERM, then SIGKILL after 5 s (`:12-13,228-255`). Crash backoff: 5–60 s, ≤5 per hour (`:14-16,195-208`). Daily cap reached (exit 4): blocked until midnight (`:181-187`). Reconciled on every lobby broadcast (`index.js:818-819`).

**Standalone mode.** Any member can run `index.mjs --circle --passcode [--e2ee]`. This is the only way into E2EE circles (`CONTRACT.md:8-17`; `docs/ai-voice-bot.md:241-260`).

**What it hears.**
- It runs `autoSubscribe:true` and **subscribes to every remote audio track** except its own, `u_ai_*` and `bot:*` (`room.mjs:94,103-119`; `pipeline.mjs:421`).
- Per-speaker pipeline: local energy VAD runs on-box (`audio.mjs:80-125`) → on VAD onset it opens a per-speaker **DashScope ASR** WebSocket, sending 300 ms of pre-roll and ~1 s of hangover (`pipeline.mjs:145-187`); the socket closes after 20 s idle (`:225-229`) → the wake word is matched against the **ASR final text** (`pipeline.mjs:443-464`; `wake.mjs:109-150`).
- **Consequence: in the default `wake` mode, all voiced speech of every human goes to Alibaba.** Non-matching finals are dropped and not stored (`:455-463`). `always` mode triggers the LLM on every final (`:451-454`). In **`ptt` mode, or when a cap is hit, no audio goes to the cloud** (`:146,352-377`).
- Text trigger: `@AI` / `@name` in `lares.chat` (`pipeline.mjs:466-472`).
- Opt-out: `capack{on:false}` closes that person's ASR (`pipeline.mjs:403-412`). ⚠️ The bot never sends `capreq`, so it usually never receives the opt-out (`docs/ai-voice-bot.md:342-343`).

**What it sends to Alibaba (DashScope).** Host: `LARES_DASHSCOPE_HOST`, default `dashscope.aliyuncs.com`. ASR: `qwen3-asr-flash-realtime` with audio only; **No speaker name is sent to ASR** (`providers/dashscope.mjs:8-34,83-130`). TTS: `qwen3-tts-flash-realtime`, which receives reply text only (`:148-215`).

**What it sends to the LLM (DeepSeek, or DashScope as fallback).**
- `POST {LARES_AI_LLM_BASE_URL}/chat/completions` with `stream:true` (`providers/openai_compat.mjs:3-7,52-62,129-152`). The DeepSeek default is `deepseek-flash` with thinking disabled.
- Context: system prompt = persona + name + "user messages are 「名字: 内容」" (`pipeline.mjs:500-505`); each user turn is formatted as **`${displayName || userId}: ${query}`** (`:447,471,530`); plus the **last 10 turns shared across all speakers** (`:310,531`; `history.mjs:92-108`).
- **There is no de-identification.**

**Outputs.** Reply text as chat on `lares.chat`, sender `u_ai_…`; captions as `cap_ai_*` on `lares.cap`; state frames `{t:'state'}` on `lares.ai`. Cites: `room.mjs:219-234`; `pipeline.mjs:394-399,634-678`. On the app side, `AiStateHolder` accepts `u_ai_` frames only and is display-only (`app/lib/src/state/ai_state.dart:36-45,114-140`; `app/lib/src/rtc/livekit_ai_state_wiring.dart:35-42`).

**What it stores and logs.**
- **History is in memory only.** It is lost on exit and not cleared on hot config reload (`history.mjs:92-108`; `pipeline.mjs:339-348`).
- Usage file `DATA_DIR/ai_voice_usage/<cid>.json` holds counts only: `{turns,llmIn,llmOut,ttsChars,asrSec}` per day plus the last hour's turn timestamps. Kept for 14 days (`caps.mjs:65-84`; `ai_voice_supervisor.js:30,102`).
- **Turn metrics.** Every `turn` event is echoed to stderr (`index.mjs:176-178`), and the supervisor logs **all child stderr verbatim**, up to 4000 chars per line (`ai_voice_supervisor.js:128,351`). With `LARES_AI_LOG_TEXT=1`, `query` and `reply` text are added (`pipeline.mjs:695`), so the **text lands in server logs / journald / docker json-file**. The child inherits this env var server-wide (`ai_voice_supervisor.js:89-95`); the e2e tool sets it (`server/tool/ai_voice_e2e.mjs:149`).
- Otherwise logs carry codes, latencies and character counts only.

**`u_ai_` identity and `aiAuth`.**
- userId = `u_ai_` + `sha256(circleId)[:8]` (`index.js:793`; `room.mjs:39`).
- Secret = `HMAC(LARES_AI_MEMBER_KEY || random-per-boot, 'lares-ai-member:'+cid)`, passed via child env `LARES_AI_MEMBER_SECRET`; the master key is stripped from the child (`index.js:789-801`; `ai_voice_supervisor.js:94-100`).
- The proof `hello.aiAuth={circleId, proof:HMAC(secret, nonce:userId:circleId)}` is checked in constant time (`room.mjs:165-167`; `index.js:794-801`). Normal circle auth is still required: the supervisor passes the stored verifier (`index.js:2223-2232`). Self-claimed `u_ai_` ids are rejected as `userId_reserved` (`index.js:1227-1229`).
- What a `u_ai_` identity changes: it is **not counted as a human**; not a push target; **not a transcript relay recipient**; excluded from focus; cannot set a profile (`index.js:632-637`; `transcripts.js:262`; `push_triggers.js:17,39`; `focus.js:202-203`; `profile.js:56-59`). It is **visible** in the room and publishes a mic track (`CONTRACT.md:31-32`). Standalone mode without the secret falls back to a `u_aibot_…` id as a normal member (`index.mjs:88-89`).

**Config** (`server/src/ai_voice_config.js:8-51`; broadcast to members, so no secrets).

| Field | Default | Allowed |
|---|---|---|
| `name` | 小助手 | ≤16 |
| `wakeWords` | 小助手 | ≤100 |
| `persona` | default persona | ≤1000 |
| `trigger` | `wake` | `wake` \| `always` \| `ptt` |
| `voice` | Cherry | — |
| `model` | qwen-flash | — |
| `maxReplyChars` | 120 | 20–400 |
| `maxTurnsPerHour` | 30 | 1–200 |
| `maxTurnsPerDay` | 200 | 1–2000 |
| `interrupt` | true | — |

- Hard-coded values: `historyTurns` 10, preroll 300 ms, hangover 1000 ms, `asrIdle` 20 s (`pipeline.mjs:151-310`). Keys come only from env: `LARES_DASHSCOPE_API_KEY`, `LARES_AI_LLM_{BASE_URL,KEY,API_KEY,MODEL,EXTRA_BODY,TIMEOUT_MS}` (`providers/index.mjs:18-52`; `deploy/systemd/lares.env.example:57-65`).
- Plugin manifest permissions: `circle:read, members:read, chat:read, chat:send, captions:send`. The description mentions only DashScope, not DeepSeek (`plugins.js:156-167`).

---

## 5. Plugins API, focus plugin, bots: who can read room content

**Permission model.** Eleven permissions: `circle:read, members:read, chat:read, chat:send, captions:read, captions:send, transcript:read, state:read, state:write, storage, focus:read` (`server/src/plugins.js:23-26`). Event → permission gate **for webhooks only** (`:28-36,313-325`). Limits and authority: ≤10 plugins per circle; the `lares.` prefix is reserved; install, uninstall and config require the `ownerKey` (`docs/plugin-api.md:75-97`).

**Server → third-party webhook.** Body: `{id,type,circleId,pluginId,ts,data}` with **raw event data** (`server/src/plugin_webhooks.js:265`): transcript lines `{userId,name,text}`; presence, join and leave carrying `{userId,name,status}`; focus events. Hardening covers SSRF only: https, private IPs blocked, IP pinned, 5 s timeout, 4 attempts (`plugin_webhooks.js:3-39`). **Only the owner consents. There is no per-participant consent and no de-identification.**

**Client WebView plugins (`window.lares`).**
- What the host relays (`app/lib/src/plugins/plugin_panel.dart:88-92,135-171`): **all member chat** `{userId,name,text}`; final captions; transcript lines. This content is **decrypted even in E2EE circles** (`docs/plugin-api.md:318-324`).
- `sendChat` posts as the member (`plugin_panel.dart:202-208`). Storage: `plugin_storage.<cid>.<pluginId>` in prefs, ≤64 KB (`app/lib/src/plugins/plugin_bridge.dart:59-95`). Nothing stops the page's JS from POSTing what it reads back to its origin (`docs/plugin-api.md:284`).

**Consent.** Scope is per device, per circle×plugin; fingerprint `sha256(origin|perms)`; all-or-nothing (`app/lib/src/plugins/plugin_consent.dart:19-40,107-137`). The shipped model differs from the original sketch in `docs/plans/plugin-protocol.md:58-78,135-148`, which said "插件永远拿不到密钥" (plugins never get keys).

**Focus.** Server file `DATA_DIR/focus/<cid>.json` holds `{names, days:{date:{uid:ms}}, totals}` (`server/src/focus.js:54,74-87`): days are pruned after 60 days; `totals` and `names` are unbounded. `focus_social.json` holds streaks, weekly stats, and cards (cards kept 7 days) (`server/src/focus_social.js:6,18,86`). This identified attendance data is **readable by bots and plugins even in E2EE circles** (`docs/plugin-api.md:420`).

**Who can read room content today.**

| Reader | Can read | Cannot read |
|---|---|---|
| Every member | Everything in the room | — |
| Passcode-holding member bots | Everything (incl. E2EE) | — |
| Hosted AI voice | All voiced audio (non-E2EE) | — |
| REST bots / plugin tokens / webhooks | Plaintext archive, member list, presence, focus | Member chat, live captions |
| WebView plugins | Chat, captions, transcript for the viewing member (decrypted) | — |
| Server operator | Non-E2EE archive, voice notes, all metadata | — |
| LiveKit operator | Non-E2EE media and data | — |

---

## 6. Recording (`rec_consent`)

**Gating.** Compile-time flag `LARES_RECORDING`, default **false** (`app/lib/src/config.dart:33-42`); recording code is tree-shaken out and the UI hidden (`main.dart:447-461`; `settings_sheet.dart:242-249`). Server feature `recording` defaults to false; `rec_start` while it is off returns `rec_error{feature_off}` (`server/src/features.js:12-15`; `index.js:1558-1559`).

**Protocol: 「先广播,后采集」 (announce first, then capture)** (`docs/recording-consent-protocol.md:27-74`).
- `rec_start` → server broadcasts `member_rec{userId,name,active,since}` to everyone, the sender included → the client captures **only after its own echo**; it fails after 5 s (`app/lib/src/recording/recording_consent.dart:1-11,314,425-490`).
- Keepalive: heartbeat every 15 s via `rec_ping`/`rec_pong`; the server sweeps stale entries at 45 s (`index.js:222-245,1594-1604`). If signaling is lost, recording auto-stops after a 10 s grace (`recording_consent.dart:776-791`).

**This is notice, not consent.** There is no opt-in or veto for the people being recorded (`docs/recording-consent-protocol.md:354-362`).

**Storage.** Files at `<root>/<cid>/<session>.jsonl` containing `{speakerIdentity,speakerName,text,...}` (`app/lib/src/recording/transcript_store.dart:98-106,191`); the DiskGuard policy keeps 30 days (`disk_guard.dart:24-26`). STT order is local sherpa → Groq → off (`stt_registry.dart:22-31,126-138`). ⚠️ No production instantiation of `TranscriptStore` / `RecordingService` was found, so this path is effectively unwired.

---

## 7. Persistence inventory

### 7.1 Server (`DATA_DIR = $LARES_DATA_DIR ?? server/data`)

`DATA_DIR` is set at `index.js:362-363`. Deployments: Docker volume `lares-data` (`docker-compose.yml:82,128-129`); systemd `/var/lib/lares`.

| File | Contents | Conversation-derived | Retention / clearing |
|---|---|---|---|
| `transcripts/<cid>.jsonl` | `{userId,name,text,...}` | **yes, plaintext** | **none**; owner clear / circle delete |
| `transcripts/_seq.json` | seq floor | no | circle delete |
| `transcript_relay/<cid>.json` | ciphertext queues + **all-time member list** | ciphertext + metadata | 30 d / 5000 per user; ack removes |
| `notes/<cid>/<uuid>.json` | **plaintext voice audio** + userId, name | **yes (raw voice)** | until listener DELETE; **no TTL; not removed on circle delete** (`index.js:1690-1724,2009-2046`) |
| `circles.json` | verifier, ownerHash | no | tombstone forever |
| `circle_settings.json` | flags, purpose | no | circle delete; written without 0600 |
| `push_subscriptions.json` | APNs token, userId, circles, tz | metadata | unregister; corrupt copies kept |
| `bot_tokens.json` | token sha256 | no | revoke / delete |
| `plugins.json` | plugin config + **shared state** | possibly | circle delete |
| `focus/<cid>.json`, `focus_social.json` | identified attendance | behavioural | days 60, cards 7 d, totals unbounded |
| `push_triggers.json` | trigger config | no | circle delete |
| `ai_voice_usage/<cid>.json` | counts only | no | 14 d; ⚠️ not deleted on circle delete |

### 7.2 Logs

- Docker `json-file` 10 MB × 3 per service (`docker-compose.yml:32-36`); systemd → journald, host-default retention; Caddy logs at WARN; LiveKit at `info` (`livekit.yaml:6-8`).
- Content enters logs **only** via the AI bot with `LARES_AI_LOG_TEXT=1` (§4). `transcript_ws` errors log `e.message` only.

### 7.3 Client

**SharedPreferences (plaintext).**
- `settings_store.dart`, keys `lares.*` (`:46-63`): `captionsProvide`, `captionsE2eeCloud`; `privacyAck.<cid>`, `ownedCircles`.
- `identity.dart:79-83`: `userId`, `name`, `emoji`, `bio`. `circle_store.dart:67-68`: `lares.circles`. `e2ee_store`: the ids of E2EE circles. `lares.blockedIds` (`block_store.dart:17`). `lares.p2p.turnPass` — plaintext (`ice_store.dart:16-22`). `plugin_storage.*` and `plugin_consent.*`.

**Secure storage.** Passcode, owner key, verifier, token (`secret_vault.dart:94-110`).

**Files.** `lares_transcripts/<cid>.jsonl`: **plaintext E2EE transcripts, no TTL** (§3.4); the recording transcript store (unwired); `record` temp files for voice notes ⚠️ (not explicitly deleted, `voice_notes.dart:124-166`).

**Memory only.** Chat (≤200 messages, `chat_service.dart:35-36,378-381`); live captions (30 lines); voice-note list; location.

**Circle removal and dissolve.** `forgetCircleSecrets` clears the owner key, verifier and privacyAck (`settings_store.dart:607-621`); it does **not** clear local transcripts or `plugin_storage`. The dissolve path also skips the E2EE flag (`main.dart:375-376`).

---

## 8. Moderation and safety roles

**Roles.** The **only server-side role is the circle owner**, and only for registered circles (`index.js:481-486,803-808`); env circles have no owner. No admin or moderator exists. `role: owner|member|bot` is planned; "将来可能有 moderator、guest" (moderator and guest may come later); multiple admins are deferred (`docs/plans/identity-and-roles.md:78,171,231-232,248`).

**Owner actions.** **Kick:** not a ban, the user can rejoin (`index.js:1490-1519`). **Change passcode:** the effective eviction. **Dissolve:** also removes plugins (`server/src/plugins.js:773-778`). **Knock mode.** **There is no persistent ban.** The only block is the per-IP auth-failure limit.

**Block.** A local `lares.blockedIds` list. Blocked users' LiveKit audio is muted locally, and the server never learns about it (`app/lib/src/moderation/block_store.dart`; `block_audio_enforcer.dart:1-57`).

**Report.** **There is no server path.** The app copies text to the clipboard and opens `mailto:support@laresapp.org` (`app/lib/src/ui/moderation_menus.dart:54-80`; `app/lib/src/moderation/report.dart:105-157`). The text includes the reported userId and name, circleId, reason, and a **≤200-char verbatim excerpt**, plus the reporter's userId.

**Content-policy acceptance:** `lares.contentPolicyAcceptedVersion` (`consent_store.dart:14`).

**"Safety officer" (安全员).** Appears only in the **untracked UI mock** `app/lib/src/chatham_preview/`, which nothing in `app/lib` imports:
- `chatham_data.dart:4-22,47-76`: an `officer` seat flag; "安全员不投票" (the safety officer does not vote); redaction categories identity/org/detail/quote.
- `convene_sheet.dart:80-123`: "可看原文,不能发布" (can see the original text, cannot publish); a release threshold of 4/5; "本机转写…只存内存" (on-device transcription, memory only); "答完即忘" (forgets once answered); a gatekeeper that "去名去机构" (removes names and organisations).
- No such concept exists in the server or shipped app.

---

## 9. Privacy docs (`docs/privacy.md`)

**Promises, with whether the code bears them out:**
- No accounts or analytics SDKs (`:15-16,246-251`). Secrets live in OS secure storage (`:39-40`). ✔ (`secret_vault.dart`, with a memory fallback). Voice is not recorded; chat and images are not stored (`:46-47`). ✔ (chat is memory-only). Presence, profile and location are memory-only on the server (`:48-50`).
- Captions: your own mic goes to Alibaba, and neither the app nor the server stores audio or caption text (`:66-85`). ✔ Mismatch: the doc says the temporary token lasts about a minute (`:84`); the code uses 5 min.
- Non-E2EE transcript: stored on the server with nickname and userId until the owner clears it or the circle is deleted (`:89-97`). ✔
- E2EE transcript: AES-256-GCM; the relay keeps 30 d / 5000; it is stored on each device and removed on uninstall or owner clear (`:101-108`). ✔ Undisclosed: the local copy is **plaintext at rest** and survives leaving the circle.
- Bots read transcripts and cannot impersonate; none run in E2EE circles (`:112-117`). Plugins: webhooks send events, including transcripts, to third parties; shared state is server-visible even under E2EE (`:123-133`).
- AI assistant: voice goes to Alibaba ASR; text plus speaker nickname plus recent turns go to DeepSeek; the server keeps usage counts only (`:139-148`). ✔ Undisclosed: with `LARES_AI_LOG_TEXT`, text reaches the logs.
- Focus: daily totals for ~60 days (`:161-168`). Push: deleted when push is turned off (`:184`). The E2EE key never leaves the device (`:227-228`).

**Contradictions:**
- "语音便签是唯一会落盘的内容" (voice notes are the only content written to disk) (`:58`) is contradicted by the same doc (transcripts `:94`, plugins `:52`, focus `:53-54`, push `:55`) and by the code.
- Voice notes kept until listened to (`:63`): the doc does not say they survive circle deletion.
- "退出圈子即停止一切数据交换" (leaving a circle stops all data exchange) (`:267`): local transcripts and plugin storage remain.
- "卸载即清除" (uninstalling clears everything) (`:266`): ⚠️ iOS Keychain items can survive an uninstall.

**In-app summary.** `app/lib/src/privacy/privacy_summary.dart:103-127` hashes the active features (ai, captions, e2ee, focus, map, plugins, recording, transcript) into a per-circle ack fingerprint. The sheet is `privacy_sheet.dart:68-121`.

---

## 10. Gaps and constraints for Chatham House mode

### 10.1 What leaks today

1. **Identified plaintext transcripts on the server**, no TTL, pageable in full by any bot or plugin token (§3.4, §3.5).
2. **Identified transcripts sent to third parties:** SSE `transcript` events and plugin webhooks; no de-identification hook exists anywhere (`plugins.js:313-325`; `plugin_webhooks.js:265`); manifest permissions are not enforced on REST/SSE.
3. **WebView plugins receive decrypted chat, captions and transcripts** with `userId`+`name`, and can exfiltrate them to their origin.
4. **The hosted AI sends all voiced speech of all humans to Alibaba.** In wake mode the wake gate is applied *after* cloud ASR; speaker names/userIds and 10 turns of shared history go to DeepSeek; with `LARES_AI_LOG_TEXT=1`, text lands in server logs (§4).
5. **Captions**: each speaker's audio goes to Alibaba; the `captionsProvide` default is **true**; turning on the archive alone starts transcription for everyone who is willing.
6. **E2EE transcript copies:** a **plaintext** local copy sits on every past member's device, with no TTL; the server keeps an all-time member list and ciphertext queues for 30 d.
7. **AI replies are published as ordinary `lares.chat`/`lares.cap`** under the `u_ai_` id. ⚠️ Whether they get archived depends on the client's transcript path. Bot `/captions` finals *are* archived.
8. **Metadata always visible to the server:** presence, join/leave times, location, P2P SDP (which contains IPs), recording flags, focus attendance, push circles; voice notes, stored as plaintext audio.
9. **Reports email a verbatim, identified ≤200-char excerpt** to support.
10. **No rotation on kick.** A removed member keeps the key until the passcode is changed.

### 10.2 What would need to change for "AI leaves no trace"

- **AI placement:** on-device, or a member-run standalone bot inside an E2EE circle. The hosted bot is structurally barred from E2EE circles and needs cloud ASR and a cloud LLM.
- **History:** keep it in memory only; it already is (§4). A mode switch would also have to: suppress chat/caption publication of AI output, or mark it non-archivable; drop the `turn` stderr echo and `LARES_AI_LOG_TEXT`; skip the `ai_voice_usage` file, or keep counts only.
- **Gate the wake word before cloud ASR**, e.g. a local KWS, or use `ptt`.
- **Introduce a mode flag that the server enforces** (`=== true`-style, like `e2ee`). It would block: `transcript_append`, `transcript_relay`, `/captions` archiving; SSE/webhook content events; voice notes; the `rec_*` paths.
- **Client side of the same flag:** skip `LocalTranscriptStore`; stop relaying chat and transcript to WebView plugins.
- **Third-party processor retention** (Alibaba, DeepSeek) is outside the repo's control. A strict "no trace" guarantee needs on-device ASR and LLM, or contractual zero-retention terms ⚠️.

### 10.3 What would need to change for "P2P transcription"

- **The P2P stack has no data channel** today. Transcript or caption fan-out needs an `RTCDataChannel` added to `p2p_session.dart`, plus mesh forwarding, which the host currently lacks.
- **Mesh size is limited to `kMeshMaxPeers = 4`.** The star needs the host to relay audio and data, and that is not implemented.
- **The mesh still needs the signaling server** for SDP, which is plaintext and exposes IPs. Only the 1:1 manual-code path is serverless; there is no default STUN/TURN, so it works on LAN only out of the box.
- **Alternatively, keep LiveKit E2EE plus on-device ASR**, because each client already transcribes only its own mic: replace `QwenRealtimeStt` with a local engine; keep the `lares.cap` and `capack` protocol, which is already E2EE in the data channel. This removes the cloud hop without needing P2P media.
- **LiveKit `TranscriptionEvent` cannot be produced by clients** (`DECISIONS-2026-09.md:116-118`). STT must run on local PCM.
- **flutter_webrtc gives no PCM.** LiveKit renderer/mic taps exist, but they have silent-death pitfalls on reconnect and `restartTrack` (`DECISIONS-2026-09.md:101-112`).

### 10.4 Platform constraints

**iOS background:**
- `UIBackgroundModes` = `audio` only (`app/ios/Runner/Info.plist:94-100`); `fetch` was removed. No VoIP/PushKit/CallKit: CallKit is restricted in mainland China, and silent-audio keepalive is forbidden (`docs/app-store/appstore-compliance-research.md:588,597,606-613`).
- Mic capture must *start* in the foreground (`app/ios/LaresWidget/ToggleMuteIntent.swift:29-36`). ⚠️ Untested: sustained CPU-heavy on-device ASR in the background. Signaling heartbeat is 20 s and gets suspended in the background (`app/lib/main.dart:465`).

**Android:** the foreground service runs only while in a room, with wake lock and Wi-Fi lock held (`app/lib/src/platform/foreground_service.dart:6-52`).

**On-device model size:** SenseVoice int8 is 228 MB, a runtime download, non-streaming, and uses hundreds of MB of RAM; the sherpa native libs add ~21.4 MB to the Windows binary; the streaming zipformer is small but scored CER 16.8%, against 3.0% for the cloud engine, and is weak on zh/en mix; App Store 2.3.1 forbids shipping dormant native libs; no ASR package is currently in `pubspec.yaml`.

**LiveKit data channel:**
- Max ~15,000 B per packet (`kStreamChunkSize`). `publishData` does **not** check length; oversize packets fail silently (`app/lib/src/chat/chat_limits.dart:7-17`). `reliable` must be set explicitly; the default is lossy.
- Targeted delivery via `destinationIdentities` is supported; relevant to "officer-only" raw text, but the SFU still sees routing metadata.
- Image chunking is 12,288 B per chunk with app-level reassembly. SDK byte streams were rejected because of ordering bugs (`app/lib/src/chat/image_assembler.dart:3-19,115-125`).

**LiveKit room cap:** `max_participants 20` (`livekit.yaml`).

**E2EE limits:** only one shared key per circle; there is no sub-group key, so an officer-only or AI-only domain would need a new HKDF `info`, following the precedent `lares-transcript-v1`. On Web, E2EE depends on insertable-streams support (`app/lib/src/e2ee/e2ee_platform.dart:11-28`).
