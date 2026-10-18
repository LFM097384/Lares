# anonym-agent core — implementation contract (internal, binds the core modules to each other)

Binding spec: `../INTERFACE.md`. This file pins the internal seams the spec leaves open.
The prototype `server/chatham/` is frozen and untouched (its tests keep passing as-is); the layers were
forked into `core/gate/` and evolved there as Gate v2.

## Layout
```
core/index.mjs        createSession + Session (RAM ring buffer, ask/draft/review/approve/released/end)
core/crypto.mjs       canonicalJSON, sha256hex, verifyEd25519(pubKey, msg, sig)
core/memory.mjs       createMemory({ storage }) + jsonFileStorage(path) + memoryStorage()
core/mock-llm.mjs     createScriptedLLM(fn) for tests
core/gate/            l0..l4.mjs, llm.mjs, gate.mjs (Gate v2)
test/*.test.mjs       node:test files; ../index.js loads them all (node --test server/anonym-agent/)
eval/                 run.mjs, judge.mjs, metrics.mjs, data/*.json, results.md
```

## Injected LLM
```js
llm = { async chat(messages, { json=false, temperature=0.3, maxTokens=8192 } = {}) -> { text, usage, finish } }
```
- `core/gate/llm.mjs` exports `createDeepSeekLLM({ baseUrl='https://api.deepseek.com', key, model='deepseek-flash' })`
  (POST /chat/completions, body has `thinking:{type:'disabled'}`, max_tokens 8192, retries; never logs/echoes the key),
  `chatJSON(llm, messages, opts)` (parse + one retry), `parseJSON`.
- No module reads an API key from env except the eval runner (`LARES_AI_LLM_KEY`).
- `llm == null` → deterministic mock paths (the prototype's mock L3/L4).

## Gate v2 API (`core/gate/gate.mjs`)
```js
runGate({ roster, lines, sessionDate, lang }, { llm=null, layers=['L0'..'L4'], threshold=0.5, flagThreshold=0.7,
          maxVerifierRounds=2, seed=1, allowPublicFacts=true, stats })
 -> { digest, digestStrict, claims:[{ topic, text, kind, flags[], risk?, confidence?, reason?, guess? }], meta }
```
- `kind`: `idea|decision|todo|fact` (L3 emits it; fallback heuristic: 待办/Action → todo, 决定/决议/agreed/decided → decision, flags has public-fact → fact, else idea).
- `flags`: subset of `public-fact`, `tone-neutralised`, `role-revealing`.
- roster entries may carry optional `works?: string[]` (published works, e.g. `《XX》`) and `publicName?` — anything there is participant identity and is always redacted.
- Also exports `verifyClaims(texts, roster, { llm, threshold, flagThreshold, maxRounds })` → `{ items:[{ text, risk?, reason?, confidence? } | DROP], flagged }` (thin wrapper over L4) for the memory mosaic check.

## Session ↔ memory seam
- `createSession({ sid, roster, policy, llm, clock, memory?, circleId? })`.
- On release, Session calls `memory.addRelease({ circleId, sid, draftId, items:[{text, kind}], approvals, approverIds })`.
- `ask` = in-room: context = raw buffer + `memory.recall(circleId, question)`. Never leaves the room.
- Outward consumers use `memory.recallForOutput(...)` / `session.released()` only.

## Session/memory notes (session-core implementer, 2026-10-18)
Contract as amended by the server integrator (binding; overrides the earlier `circleId`-per-call memory shape).

### LLM
- Only `res.text` of `llm.chat(...)` is used; `usage` optional. `llm == null` → mock everywhere.

### Session (`core/index.mjs`)
- `createSession({ sid, roster, policy:{ k, flagThreshold=0.7, allowPublicFacts=true, bufferSize=5000, threshold=0.5, lang? }, llm, clock, memory?, gate? })`.
  `memory` is that circle's store. `gate` = optional `{ runGate, NOTICE? }` override for tests (default: `./gate/gate.mjs`).
  If `k` is missing: `min(n, ceil(n/2)+1)`.
- runGate is called as `runGate({ roster, lines:[{speakerId,speakerName,text}], sessionDate, lang }, { llm, mock: !llm, threshold, flagThreshold, allowPublicFacts })`
  (both `llm` and `mock` passed, so the v1 and v2 signatures both work).
- Errors: thrown `Error` with `.code` ∈ `ended, not_member, bad_member, empty, empty_question, unknown_draft, unknown_item, bad_action,
  already_released, hash_mismatch, bad_nonce, bad_key, key_mismatch, bad_sig, replay`.
- `ingest`: non-roster speaker → throws `not_member`. Non-final utterances are buffered but never used by draft/ask. Ring buffer keeps the last `bufferSize`.
- `leave` only marks the member as not present. They stay on the roster, so the gate keeps redacting their name and they can still review/approve.
- `ask` is **async** and returns `{answer}`. Its context is the final buffer lines with speaker names (in-room) plus `memory.recall(question,{limit:5})`.
  The mock answer is the top recalled items plus the best-matching utterances. Question and answer are not retained.
- `draft` is async. Items are `{ id:'i<n>', topic, text, kind, roleRisk, reason?, flags[] }`. `topic` is an extra field, used as a section heading in the release.
  `kind` falls back to the heuristic in this file. Any `claim.risk` adds `role-revealing` and sets `roleRisk`. `reason` is review-only: it never goes into the release or memory.
- `draftHash = sha256hex(canonicalJSON({ sid, draftId, items:[{ id, kind, roleRisk, text, topic }] }))`. roleRisk and topic are included because they change what is released.
  `canonicalJSON` sorts keys recursively, has no whitespace, and omits undefined keys.
- `review` is **async** (generalise may call the llm). Every content change produces a new hash and clears **all** approvals on that draft.
  - `cut` removes the item.
  - `keep` on a roleRisk item clears roleRisk and `reason` and adds the flag `reviewed-keep` (new hash). On a non-risk item it is a no-op: same hash, approvals kept.
  - `generalise` asks the llm for JSON `{text}` (roster tokens stripped). If there is no llm or it fails, the deterministic `mockGeneralise` runs instead: it strips roster tokens, numbers → 若干, quotes and 《》 → generic text, and adds a `（概括）`/`(generalised)` prefix. The item gets the flag `generalised` and roleRisk is cleared.
  - Review after release → `already_released`.
- `approve`: the signature is Ed25519 over `canonicalJSON({sid,draftId,draftHash,nonce})` (`approvalMessage()` in crypto.mjs).
  - `pubKey` may be base64/base64url raw 32 bytes, PEM, or a KeyObject. `sig` is base64.
  - Check order: `ended`, `not_member`, `unknown_draft`, `hash_mismatch` (must be the current hash), `bad_nonce`, `bad_key`, `key_mismatch`, `bad_sig`, `replay`.
  - Nonces are global per session and are only consumed by a valid signature.
  - **Key binding / TOFU**: a key comes from the roster entry's `pubKey` or from `join({pubKey})`. Otherwise the first verified approval pins it. A different key later → `key_mismatch`.
  - Only distinct roster members are counted. Approving again with a fresh nonce is accepted but not double counted.
- Release happens when approvals ≥ k. **Fail closed**: items still `roleRisk` (not kept/generalised) are excluded.
  - The text is the gate `NOTICE` plus `# Digest (session YYYY-MM-DD)` plus `## topic` sections.
  - After release, the session calls `memory.addRelease({ sid, draftId, approvals, k, items:[{id,text,kind}], approverIds, releasedAt })`.
  - If memory throws, the release stands and `metrics.memoryError` gets the code only.
- `released(draftId)` → `{ text, items:[{id,text,kind}] } | null`. It still works after `end()`, because released text is not raw.
- `end()` → `Receipt { sid, counts:{utterances, drafts, releases, approvals}, releases:[{draftId, sha256}], sha256 }`, where
  `sha256 = sha256hex(canonicalJSON({ sid, counts, releases }))` and each `releases[].sha256 = sha256hex(released text)`.
  - `utterances` counts every accepted ingest, including non-final ones.
  - `approvals` counts every accepted signature, including ones later invalidated by a review.
  - The wipe clears the buffer, draft items/reasons/topics, approvals, nonces and keys. The roster is reduced to `{id}`.
  - `end()` is idempotent and returns the same receipt. Afterwards every method except `released`/`end` throws `ended`.
- `_inspect()` is a test/debug deep copy of all internal state. It must never be exposed outward.

### Memory (`core/memory.mjs`) — one store per circle
- `createMemory({ circleId, data?, storage?, roster?, llm?, gate?, clock? })`.
  - With a `storage` adapter `{load(), save(snapshot)}` (`memoryStorage()`, `jsonFileStorage(path)`), it loads on create and saves the whole snapshot after each mutation.
  - `jsonFileStorage` writes atomically: a tmp file in the same directory, then rename.
  - `data` = a `toJSON()` snapshot. A snapshot from a different `circleId` → `circle_mismatch`.
- Item = `{ id, circleId, text, kind(idea|decision|todo|fact, default idea), sid, releasedAt, approvals }`. Fields are whitelisted, so speaker/reason/flags are never stored.
  - Release records are stored separately: `{ releaseId, sid, draftId, releasedAt, k, approvals, itemIds, approverHashes }`.
  - `approverHashes = sha256hex('anonym-approver:'+circleId+':'+memberId)` (no names or raw ids). They are used only to authorise retract.
- `addRelease(...)` → added items. `recall(q,{limit=5})` → live items ranked by char-bigram plus latin keyword cosine (with `score`).
- `list()` → all items. A tombstone is `{id, retracted:true, sid, retractedAt}` with no text; its text is gone from state and disk.
- `retract(itemId, by?)` → bool. It returns false if the item is unknown or already retracted, or if `by` is given, approver hashes exist and `by` is not one of them.
  `by` omitted = the caller has already authorised.
- `recallForOutput(q,{limit, roster?, llm?, flagThreshold=0.7})` is **always async** and returns an items array with a non-enumerable `.flags = [{itemId, reason:'mosaic', confidence}]`. Each kept item has `flags[]`, holding sub-threshold L4 risk if any. The attacker's `reason`/`guess` are never returned.
  1. **Deterministic mosaic heuristic.** The cues are each member's org/title/publicName/works strings, their separator parts, latin words of 4+ characters and CJK runs of 2+ characters. Names are not cues, and cues shared by 2+ members are discarded. If the result set together holds 2 or more distinct cues of one member, only the best-ranked single-cue item is kept and the rest are dropped.
  2. **L4.** The survivors go through `gate.verifyClaims(texts, roster, {llm, mock, threshold, flagThreshold})` together. An item marked `DROP`, or with risk at confidence ≥ flagThreshold, is dropped. Dropped items are **not merged**.
     - If verifyClaims returns a malformed result → throws `gate_failed` (fail closed).
     - Fallback while Gate v2 has no `verifyClaims` yet: `l4.verify` with one section per text.
