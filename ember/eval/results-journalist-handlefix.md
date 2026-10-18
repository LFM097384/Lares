# Anonym Gate v2 — evaluation results

- Run: 2026-10-18T06:16:42.062Z
- Mode: LLM (gate + judge model: deepseek-flash)
- Configs: +L4; threshold=0.5; flagThreshold=0.7; attack samples=2; mosaic=false
- Transcripts: journalist (5 speakers, 9 ideas, 22 identifiers)
- Runtime / cost: wall 40s; gate tokens 16498 (≈$0.0027); judge/attacker tokens 11002 (≈$0.0012); assumed DeepSeek flash: $0.07/M in, $0.28/M out — prices are an **assumption**.
- Leak rates are pooled counts over transcripts. Random baseline = mean over ideas of 1/N speakers.

## Gate v2 metrics

New in Gate v2 (only the bookclub / policy / faculty transcripts carry this gold):
- **publicFactRetention** = public-world facts whose every `keep` string appears in the digest (normalised, case-insensitive, 《》/quotes stripped).
- **selfAuthorLeak** = participant-authored works (`gold.selfAuthor` work/fuzzy ∪ `roster[].works`) found in the digest; **publicNameLeak** = roster `publicName` found. Both must be 0.
- **toneLeak** = markers whose claim is present and the LLM judge still finds sarcasm / irony / backhanded praise / catchphrase / dialect / idiolect, OR any marker surface string appears verbatim (deterministic, OR'd) ÷ markers whose claim is present.
- **stancePreserved** = markers whose judged digest stance has the gold direction and |strength diff| ≤ 1 ÷ all markers (absent = not preserved).

| config | publicFactRetention% | selfAuthorLeak (works) | publicNameLeak | toneLeak% | stancePreserved% | directLeak% | affilLeak% | attackAcc% | retention% | flags public-fact / tone |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| +L4 | — | — | — | — | — | 0.0 | 0.0 | 88.9 | 77.8 | 0 / 0 of 52 |

## Targets (config +L4, pooled over the transcripts run)

| target | value | met |
| --- | --- | --- |
| publicFactRetention ≥ 90% | — | n/a |
| toneLeak ≤ 10% | — | n/a |
| stancePreserved ≥ 85% | — | n/a |
| selfAuthorLeak = 0 (works + publicName) | — | n/a |
| directLeak ≈ 0 (≤ 1%) | 0.0% | ✅ |
| affilLeak ≈ 0 (≤ 1%) | 0.0% | ✅ |
| outsider names 0 roster members | 0 | ✅ |
| idea retention ≥ 85% | 77.8% | ❌ |

## Aggregate (all metrics from the prototype)

| config | directLeak% | affilLeak% | quasiLeak% | styleLeak% | attackAcc% | randomBaseline% | retention% | avgLatencyMs | tokens | est$ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| +L4 | 0.0 | 0.0 | 0.0 | 0.0 | 88.9 | 20.0 | 77.8 | 29433 | 16498 | 0.00266 |

## Attacker knowledge levels

(a) full roster incl. org/title/works (insider-equivalent) = attackAcc% above; (b) names+aliases only; (c) outsider with no roster: how many roster members it can name (person or org, exact/fuzzy) and how many ideas it pins to the right person/org.

| config | (a) fullRoster attack% | (b) namesOnly attack% | (c) outsider: roster members named | (c) outsider: speaker hit% | random% |
| --- | --- | --- | --- | --- | --- |
| +L4 | 88.9 | 55.6 | 0/5 (0 by name, 0 by org) | 0.0 | 20.0 |

## Role-revealing risk flags (L4 residual)

"strict" = the digest with all flagged claims cut (full-roster attacker).

| transcript | flagged/claims | dropped | strict attack% | strict retention% |
| --- | --- | --- | --- | --- |
| journalist | 0/52 | 0 | — | — |
| ALL | 0/52 | 0 | — | — |

## Prototype → Gate v2 (same 7 old transcripts)

Prototype numbers from `server/chatham/eval/results.json` (2026-10-18T01:50:08.143Z, llm). Gate v2 numbers restricted to the same 7 transcripts. Format: prototype → v2.

| config | old transcripts | directLeak% proto→v2 | affilLeak% | quasiLeak% | styleLeak% | fullRoster attack% | namesOnly attack% | outsider named | retention% | gate est$ (total) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| +L4 | 1/7 | 0.0 → 0.0 | 0.0 → 0.0 | 10.0 → 0.0 | 11.1 → 0.0 | 72.0 → 88.9 | 42.4 → 55.6 | 0/35 → 0/5 | 89.0 → 77.8 | 0.0181 → 0.0027 |

## How to read this

- **ideas-only** is a floor: the attacker gets the roster and the bare gold idea texts, with no digest. No de-identification that keeps the idea can push the full-roster attack much below that floor.
- **(a) full roster with org/title** is an insider. **(c) outsider** is the outward threat: the digest must not reveal who attended.
- Gate v2 deliberately keeps public-world facts (named authors, laws, public bodies). The gold `org`/`title` identifiers in all 10 transcripts are participant-owned (owner p1..p5), so affilLeak keeps its meaning: any of them in the digest is a real leak.
- Attacker, gate and judges all use the same model family (deepseek-flash). n is small (10 synthetic transcripts; 15 tone markers, 21 public facts, 3 self-authored works): one marker ≈ 6.7 pts of toneLeak/stancePreserved. Judge noise matters.

## Per transcript

| transcript | config | directLeak% | affilLeak% | quasiLeak% | styleLeak% | attackAcc% | randomBaseline% | retention% | latencyMs | tokens | est$ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| journalist | +L4 | 0.0 (0/13) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/4) | 88.9 | 20.0 | 77.8 | 29433 | 16498 | 0.00266 |

## Leaked identifiers per config

_Leaked strings are redacted to their first 2 characters._

### +L4 (0 leaked)

_none_
