# Chatham Gate (prototype)

A de-identification filter that turns a voice-circle transcript into a **de-attributed digest**: what was said, without who said it.

**Scope: the "Rule-inspired" tier only.** Chatham House's own FAQ says AI notetakers are not compatible with meetings held *under* the Chatham House Rule. A strict "under the Rule" tier therefore uses no AI and no transcript at all. This Gate is for a lower, explicitly labelled tier that borrows the Rule's spirit. It makes no claim of Chatham House compliance or endorsement, and the product must not imply either.

Plain Node ≥ 20, ESM, zero dependencies.

## Usage

```pwsh
# digest one transcript (mock mode when CHATHAM_LLM_KEY is unset)
node server/chatham/gate.mjs server/chatham/eval/data/startup.json

# unit tests (L0–L2, mock L3/L4, metrics, risk flags)
node --test server/chatham/test/

# evaluation: ablation over raw, L0+L1, +L2, +L3, +L4, plus the ideas-only floor
node server/chatham/eval/run.mjs --mock                     # offline heuristics, NOT LLM numbers
$env:CHATHAM_LLM_KEY='…'; node server/chatham/eval/run.mjs --ablation --attack-samples 2
#   other flags: --layers L0,L1,L2  --only medical,ngo  --threshold 0.5  --flag-threshold 0.7  --concurrency 4
```

LLM env: `CHATHAM_LLM_BASE_URL` (default `https://api.deepseek.com`), `CHATHAM_LLM_KEY`, `CHATHAM_LLM_MODEL` (default `deepseek-flash`). The key is never logged or written to disk.

```js
import { runGate } from './server/chatham/lib/gate.mjs';
const { digest, digestStrict, claims, meta } = await runGate({ roster, lines, sessionDate });
```

## Layers

| layer | what | where |
|---|---|---|
| L0 structural | drop speaker id/name/timestamps; split into sentences; cluster into topics; shuffle topics and sentences (seeded) to destroy turn order | `lib/l0.mjs` |
| L1 PII | regex/dictionary: phones, emails, ID/bank numbers, URLs/handles, CN/EN addresses, dates; roster names plus fuzzy forms (surname+总/老师/哥/工, 老X/小X, given names, EN first/last, Dr./Ms.); third-party names in context | `lib/l1.mjs` |
| L2 affiliation | roster org fragments and titles, a known-org/title dictionary, self-affiliation phrasing ("作为X", "我在X…", "我们部门", "As head of…", "at my firm") | `lib/l2.mjs` |
| L3 rewrite | the LLM sees **only L1+L2-redacted text** and writes third-person, de-attributed claims per topic: no quotes > N chars, no tics, quasi-identifiers generalised | `lib/l3.mjs` |
| L4 verifier | an attacker LLM gets the roster and guesses each claim's speaker. Claims at ≥ `threshold` are generalised (or dropped if no rewrite comes back; fail closed), for up to 2 rounds. A final attack pass marks claims still at ≥ `flagThreshold` as **`[review: role-revealing]`** | `lib/l4.mjs` |

A final L1(+L2) scrub runs over all LLM output. Placeholders are un-numbered (`[参与者]`, `[某机构]`, `a participant`, …), so they cannot be used to link claims to each other.

**Role-revealing flags.** The Gate does not silently keep or drop residual-risk claims. Each claim in `claims[]` carries `risk`, `confidence` and an attacker `reason`. Human reviewers in the k-of-n release step decide to keep, generalise or cut each one. `digest` contains the flagged claims, prefixed; `digestStrict` omits them. `reason`/`guess` may name an attendee, so they are review-only and must never be exported.

## Results (DeepSeek `deepseek-flash`, 7 synthetic zh/en transcripts, 5 speakers each, 59 gold ideas)

Full tables are in [`eval/results.md`](eval/results.md). Random baseline is 20%.

| config | direct leak | affil leak | (a) full-roster attack | (b) names-only attack | (c) outsider: members named | retention |
|---|---|---|---|---|---|---|
| ideas-only floor | – | – | 62.7% | 47.5% | – | – |
| raw | 100% | 100% | 97.5% | 98.3% | 35/35 | 99.2% |
| L0+L1 | 1.1% | 100% | 72.0% | | | 91.5% |
| +L2 | 0% | 0% | 75.4% | | | 92.4% |
| +L3 | 0% | 0% | 72.0% | 45.8% | 0/35 | 87.3% |
| +L4 | 0% | 0% | 72.0% | 42.4% | 0/35 | 89.0% |

- L4 flagged 32 of 360 claims (9%), touching 9 of 59 gold ideas. Cutting every flagged claim ("strict") leaves the full-roster attack at about 65% while retention falls to about 77%.
- L4 cost about $0.018 and 30 s per meeting (≈110k tokens; the price is an assumption).

### Interpretation

- **Surface identifiers: solved on this data.** Direct, affiliation and style leaks drop to about 0. An outsider with no roster could name none of the 35 attendees or their orgs from the L3/L4 digests (raw: 35/35).
- **Insider attribution: not solvable by rewriting.** An attacker who knows the attendee list *and their jobs* still attributes about 72% of ideas, against 20% random. With just the roster and the bare idea texts and no digest at all, that attacker already gets about 63%. The residual risk is in the ideas themselves: the labour lawyer is the one citing the wage regulation, the oncologist the one arguing for surgery. The Gate reaches roughly this floor and cannot go below it without deleting the idea. That is why the target "attack ≈ random with ≥85% retention" was **not reached** against insiders, and it is not reachable for role-specific content. L4 did not move the number, because generalising role-linked content doesn't hide the role.
- With names only, attack accuracy is about 45% (floor about 48%). The attacker's world knowledge about names adds little on synthetic people.
- What protects participants against insiders is product design, not the filter: the k-of-n human review with role-revealing flags, small or homogeneous circles flagged as high-risk, and the strict tier with no AI.

## Threat model

**Covered (on the evaluation data):** an outsider who obtains the digest and tries to learn who attended or who said what. Direct PII of participants and third parties. Orgs and titles. Verbal tics and long verbatim quotes. Turn order and timestamps.

**Not covered:**
- Insiders (attendees, or anyone who knows the roster and roles) attributing role-specific content. See above: the Gate only flags it.
- Uniquely identifying *facts* (one specific project, a unique event) that are not in the dictionaries, the LLM misses, and the attacker does not flag.
- A stronger attacker than the verifier (the attacker, generaliser and judge are all deepseek-flash), or one with external data such as public talks or papers.
- Linkage across many digests from the same circle (the same idea recurring over sessions).
- The raw transcript and audio themselves. The L3 provider sees L1+L2-redacted text only, but the Gate assumes the transcript store is secured elsewhere.
- Regex and dictionary recall on unseen names and orgs. The dictionaries were tuned on this eval set, so expect lower recall in the wild.
- Coercion of, or a leak by, the human reviewers.

## Files

- `lib/` — `l0.mjs` `l1.mjs` `l2.mjs` `l3.mjs` `l4.mjs` `llm.mjs` `gate.mjs` `index.mjs`; `gate.mjs` (CLI); `CONTRACT.md` (data schema and API)
- `eval/` — `data/*.json` (7 transcripts with gold identifiers and ideas), `run.mjs`, `metrics.mjs`, `judge.mjs` (attacker levels, outsider scoring, retention judge), `inspect-l2.mjs` and `idea-flags.mjs` (dev helpers), `results.md` / `results.json`
- `test/` — `node --test server/chatham/test/` (`index.js` loads every `*.test.mjs`)

## Known issues fixed during evaluation

- **"L4 ERROR on academic"** (an earlier run): `runGate: unbalanced JSON object in LLM output`. The attacker/generaliser JSON response came back truncated: the client set no `max_tokens`, so long claim lists were cut off mid-object, and `chatJSON` did not retry. The fix sets `max_tokens: 8192`, retries once on unparseable JSON, and reports `finish_reason` in the error. All 7 transcripts have completed since.
- The ablation once applied L2 even in the "L0+L1" row; the final scrub now uses only the requested layers.
- The title `董事` matched inside `董事会` ("the board"); this is fixed.
