# lares.ai-voice — internal contract (bot process ⇄ server supervisor)

This file is the single source of truth shared by the bot implementation (`server/bots/voice-agent/`)
and the server-side supervisor (`server/src/ai_voice_supervisor.js`). Keep both sides in sync with it.

## 1. Process CLI

```
node server/bots/voice-agent/index.mjs --circle <circleId>
     [--signaling ws://127.0.0.1:8787/ws]   (default env LARES_SIGNALING)
     [--passcode <p>]                        (standalone; v1 for env circles, v2 with --auth-v2)
     [--auth-v2]                             (registered c_… circles; derive Argon2 verifier from passcode)
     [--e2ee]                                (requires --passcode; derive E2EE key like the app)
     [--config <path.json>]                  (AiVoiceConfig, see §3; also env LARES_AI_CONFIG = JSON string)
     [--providers dashscope|mock]            (default dashscope; env LARES_AI_PROVIDERS)
     [--user-id <id>] [--name <displayName>]
```

Server-managed mode (supervisor) passes secrets ONLY through the child's environment, never argv:

| env | meaning |
|---|---|
| `LARES_AI_AUTH_SECRET` | HMAC secret for the signaling challenge. For registered circles = the stored v2 verifier (hex) → bot sends `auth.v = 2`. |
| `LARES_AI_AUTH_V` | `2` or `1` (env circles with plaintext passcode use `1` and secret = passcode) |
| `LARES_AI_CONFIG` | JSON AiVoiceConfig |
| `LARES_AI_USAGE_FILE` | path of the per-circle usage/caps JSON (persisted daily counters) |
| `LARES_DASHSCOPE_API_KEY` | inherited from the server env |
| `LARES_AI_LLM_BASE_URL` / `LARES_AI_LLM_KEY` (alias `LARES_AI_LLM_API_KEY`) / `LARES_AI_LLM_MODEL` / `LARES_AI_LLM_EXTRA_BODY` / `LARES_AI_LLM_TIMEOUT_MS` | optional OpenAI-compatible override (prod: DeepSeek); inherited via env only, never argv. Falls back to DashScope qwen-flash on failure |
| `LARES_SIGNALING` | e.g. `ws://127.0.0.1:<port>/ws` |

The bot joins as a **normal visible member** through signaling (userId `u_ai_<8 hex of sha256(circleId)>` unless `--user-id`),
display name = `config.name`. It never uses a `bot:` userId (reserved by the server).

## 2. Process lifecycle / stdout protocol

- stdout: one JSON object per line, prefixed by nothing: `{"ev":"ready"|"turn"|"usage"|"cap_reached"|"error"|"exit", ...}`.
  Human-readable logs go to stderr. Never log transcripts' full text at info level in server-managed mode
  (`turn` events carry lengths + latency numbers, not content, unless `LARES_AI_LOG_TEXT=1`).
- `turn` event: `{ev:'turn', id, trigger, asrFinalAt, llmFirstTokenMs, firstSentenceMs, ttsFirstAudioMs, ttfaMs, replyChars, heardChars, interrupted}`
  (all ms relative to ASR final).
- Graceful stop: SIGTERM **or** stdin closing **or** a line `{"cmd":"stop"}` on stdin → leave room, exit 0 within 3 s.
- Config reload: a line `{"cmd":"config","config":{...}}` on stdin replaces AiVoiceConfig live.
- Exit codes: 0 normal, 2 bad args/config, 3 auth failed, 4 daily cap reached (supervisor must not respawn today).

## 3. AiVoiceConfig (= plugin `lares.ai-voice` config; all optional)

| key | type | default | notes |
|---|---|---|---|
| `name` | string ≤16 | `小助手` | display name; also an implicit wake word |
| `wakeWords` | string ≤100 | `小助手` | comma/、/space separated extra wake words |
| `persona` | string ≤1000 | (Chinese default: brief, warm, spoken style) | system prompt |
| `trigger` | `wake`\|`always`\|`ptt` | `wake` | ptt = only chat messages starting with `@AI` (or `@<name>`) |
| `voice` | string | `Cherry` | TTS voice |
| `model` | string | `qwen-flash` | LLM model |
| `maxReplyChars` | int 20..400 | 120 | |
| `maxTurnsPerHour` | int 1..200 | 30 | |
| `maxTurnsPerDay` | int 1..2000 | 200 | per circle, persisted |
| `interrupt` | boolean | true | stop speaking when a human talks over the bot |

## 4. Server supervisor rules

- Spawn when: plugin `lares.ai-voice` installed+enabled for the circle AND ≥1 human member in the room
  AND the circle is not server-E2EE (`circleSettings.e2ee === true` → refuse; E2EE requires standalone mode with passcode)
  AND `LARES_DASHSCOPE_API_KEY` (or LLM override + mock) configured.
- Stop (SIGTERM, SIGKILL after 5 s) when: room has no human (after 20 s grace), plugin disabled/uninstalled, circle deleted, server shutdown.
- Respawn on crash with backoff (5 s → 60 s), max 5 per hour; exit code 4 → no respawn until next local day.
- The bot's own member must not count as "human" (identify by userId prefix `u_ai_`).

## 5. Room data topics (bot → clients)

Besides `lares.chat` (replies as normal text messages) and `lares.cap` (captions, `{t:'cap', id, seq, text, final}`),
the bot publishes its state on **`lares.ai`** (reliable, JSON UTF-8). No text/content is ever carried on this topic.

```
{"t":"state","state":"idle"|"listening"|"thinking"|"speaking","seq":<int>}
```

| state | meaning |
|---|---|
| `listening` | in the room, trigger `wake`/`always`, and ASR not paused by the hourly/daily cap |
| `idle` | not listening to voice (trigger `ptt`, or cap pause) and no turn in progress |
| `thinking` | a turn was accepted (wake word / `@AI` chat / `always`) and the LLM was requested; no audio played yet |
| `speaking` | reply audio is playing (from the first frame); when the turn ends or is interrupted → `listening`/`idle` |

- `seq` increases monotonically per bot process (it restarts from 1 when the process respawns).
- Published only on change, plus once after joining and again whenever a participant connects (late joiners get the current state).
- Config reload changing `trigger` flips `listening` ↔ `idle` immediately.
- Clients should treat a `thinking`/`speaking` state older than ~30 s as stale (bot crashed or left mid-turn) and fall back to `idle`.
