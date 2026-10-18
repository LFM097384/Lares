# Chatham Gate — internal data contract (shared by all modules)

## Transcript file: `eval/data/<id>.json`
```json
{
  "id": "thinktank",
  "title": "...",
  "sessionDate": "2026-09-14",
  "lang": "zh|en|mixed",
  "roster": [
    { "id": "p1", "name": "王建国", "aliases": ["王总","老王","Jianguo","JG"], "org": "某某研究院", "title": "高级研究员" }
  ],
  "lines": [
    { "speakerId": "p1", "speakerName": "王建国", "text": "...", "ts": "2026-09-14T09:01:12+08:00" }
  ],
  "gold": {
    "identifiers": [
      { "text": "138-0013-8000", "kind": "phone|email|idcard|url|handle|name|org|title|address|date|quasi|style", "owner": "p1", "fuzzy": ["13800138000"] }
    ],
    "ideas": [
      { "id": "i1", "text": "Short canonical statement of a key idea that must survive", "owner": "p1" }
    ]
  }
}
```
- `kind` direct = phone,email,idcard,url,handle,name,address,date ; affiliation = org,title ; quasi = quasi ; style = style (a verbal tic like "说白了" / "frankly speaking, bottom line").
- Public roster (what an attacker may know) = `roster` entries' `name`, `org`, `title` (NOT aliases-as-secret; aliases are known too).
- Every idea has an `owner` (roster id) — ground truth for the attribution attack.

## Gate API: `lib/gate.mjs`
```js
export async function runGate(transcript, { layers = ['L0','L1','L2','L3','L4'], mock = !process.env.CHATHAM_LLM_KEY, threshold = 0.5, flagThreshold = 0.7, maxVerifierRounds = 2 } = {})
// transcript = { roster, lines, sessionDate }
// returns { digest, digestStrict, claims: [{ topic, text, risk?, confidence?, reason?, guess? }],
//           meta: { layers, llmCalls, promptTokens, completionTokens, ms, verifierRounds, dropped, flagged } }
```
- Scope: the Gate serves the **"Rule-inspired" tier** only. Chatham House's own FAQ says AI notetakers are not compatible with meetings held under the Rule, so a strict "under the Rule" tier must use no AI at all. Never describe Gate output as Chatham House compliant or endorsed.
- `digest` (or, after human review, a reviewed subset) is the only thing that may leave the room. Markdown text, topic sections, bullet claims, no speaker info. Claims still attributable at ≥ `flagThreshold` after L4 are prefixed `[review: role-revealing]`; `digestStrict` omits them.
- `claims[].reason` / `claims[].guess` come from the attacker and may name an attendee: review-only metadata, shown only to participants during k-of-n review, never exported.
- Layer modules: `lib/l0.mjs`, `lib/l1.mjs`, `lib/l2.mjs`, `lib/l3.mjs`, `lib/l4.mjs`, LLM client `lib/llm.mjs`.
- `layers=[]` ("raw") returns the transcript as `speakerName: text` lines (baseline for eval).
- LLM: env `CHATHAM_LLM_BASE_URL` (default `https://api.deepseek.com`), `CHATHAM_LLM_KEY`, `CHATHAM_LLM_MODEL` (default `deepseek-flash`); POST `/chat/completions`, body includes `"thinking":{"type":"disabled"}`. Never log the key.
