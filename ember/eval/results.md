# Anonym Gate v2 — evaluation results

- Run: 2026-10-18T06:13:18.778Z
- Mode: LLM (gate + judge model: deepseek-flash)
- Configs: ideas-only, raw, L0+L1, +L2, +L3, +L4; threshold=0.5; flagThreshold=0.7; attack samples=2; mosaic=true
- Transcripts: academic (5 speakers, 8 ideas, 22 identifiers); bookclub (5 speakers, 9 ideas, 23 identifiers, 7 public facts, 5 tone markers, 1 self-authored works); faculty (5 speakers, 9 ideas, 21 identifiers, 7 public facts, 5 tone markers, 1 self-authored works); journalist (5 speakers, 9 ideas, 22 identifiers); medical (5 speakers, 8 ideas, 22 identifiers); ngo (5 speakers, 8 ideas, 22 identifiers); policy (5 speakers, 9 ideas, 22 identifiers, 7 public facts, 5 tone markers, 1 self-authored works); startup (5 speakers, 9 ideas, 22 identifiers); thinktank (5 speakers, 9 ideas, 22 identifiers); union (5 speakers, 8 ideas, 22 identifiers)
- Runtime / cost: wall 573s; gate tokens 288793 (≈$0.0448); judge/attacker tokens 627881 (≈$0.0681); assumed DeepSeek flash: $0.07/M in, $0.28/M out — prices are an **assumption**.
- Leak rates are pooled counts over transcripts. Random baseline = mean over ideas of 1/N speakers.

## Gate v2 metrics

New in Gate v2 (only the bookclub / policy / faculty transcripts carry this gold):
- **publicFactRetention** = public-world facts whose every `keep` string appears in the digest (normalised, case-insensitive, 《》/quotes stripped).
- **selfAuthorLeak** = participant-authored works (`gold.selfAuthor` work/fuzzy ∪ `roster[].works`) found in the digest; **publicNameLeak** = roster `publicName` found. Both must be 0.
- **toneLeak** = markers whose claim is present and the LLM judge still finds sarcasm / irony / backhanded praise / catchphrase / dialect / idiolect, OR any marker surface string appears verbatim (deterministic, OR'd) ÷ markers whose claim is present.
- **stancePreserved** = markers whose judged digest stance has the gold direction and |strength diff| ≤ 1 ÷ all markers (absent = not preserved).

| config | publicFactRetention% | selfAuthorLeak (works) | publicNameLeak | toneLeak% | stancePreserved% | directLeak% | affilLeak% | attackAcc% | retention% | flags public-fact / tone |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ideas-only | — | — | — | — | — | 0.0 | 0.0 | 62.8 | 0.0 | 0 / 0 of 0 |
| raw | 100.0 (21/21) | 3/3 | 1/1 | 100.0 (15/15) | 86.7 (13/15) | 100.0 | 100.0 | 97.1 | 98.8 | 0 / 0 of 251 |
| L0+L1 | 100.0 (21/21) | 3/3 | 0/1 | 100.0 (15/15) | 86.7 (13/15) | 4.8 | 100.0 | 69.2 | 94.2 | 0 / 0 of 648 |
| +L2 | 100.0 (21/21) | 0/3 | 0/1 | 100.0 (15/15) | 86.7 (13/15) | 2.4 | 0.0 | 69.2 | 93.6 | 0 / 0 of 648 |
| +L3 | 95.2 (20/21) | 0/3 | 0/1 | 20.0 (3/15) | 66.7 (10/15) | 0.0 | 0.0 | 65.1 | 89.0 | 22 / 26 of 541 |
| +L4 | 100.0 (21/21) | 0/3 | 0/1 | 0.0 (0/14) | 80.0 (12/15) | 0.0 | 0.0 | 66.3 | 90.7 | 20 / 9 of 539 |

## Targets (config +L4, pooled over the transcripts run)

| target | value | met |
| --- | --- | --- |
| publicFactRetention ≥ 90% | 100.0% | ✅ |
| toneLeak ≤ 10% | 0.0% | ✅ |
| stancePreserved ≥ 85% | 80.0% | ❌ |
| selfAuthorLeak = 0 (works + publicName) | 0 | ✅ |
| directLeak ≈ 0 (≤ 1%) | 0.0% | ✅ |
| affilLeak ≈ 0 (≤ 1%) | 0.0% | ✅ |
| outsider names 0 roster members | 4 | ❌ |
| idea retention ≥ 85% | 90.7% | ✅ |

## Aggregate (all metrics from the prototype)

| config | directLeak% | affilLeak% | quasiLeak% | styleLeak% | attackAcc% | randomBaseline% | retention% | avgLatencyMs | tokens | est$ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ideas-only | 0.0 | 0.0 | 0.0 | 0.0 | 62.8 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| raw | 100.0 | 100.0 | 100.0 | 100.0 | 97.1 | 20.0 | 98.8 | 2 | 0 | 0.00000 |
| L0+L1 | 4.8 | 100.0 | 96.4 | 100.0 | 69.2 | 20.0 | 94.2 | 24 | 0 | 0.00000 |
| +L2 | 2.4 | 0.0 | 71.4 | 100.0 | 69.2 | 20.0 | 93.6 | 38 | 0 | 0.00000 |
| +L3 | 0.0 | 0.0 | 10.7 | 4.8 | 65.1 | 20.0 | 89.0 | 7651 | 45963 | 0.00680 |
| +L4 | 0.0 | 0.0 | 3.6 | 4.8 | 66.3 | 20.0 | 90.7 | 31751 | 185666 | 0.03019 |

## Attacker knowledge levels

(a) full roster incl. org/title/works (insider-equivalent) = attackAcc% above; (b) names+aliases only; (c) outsider with no roster: how many roster members it can name (person or org, exact/fuzzy) and how many ideas it pins to the right person/org.

| config | (a) fullRoster attack% | (b) namesOnly attack% | (c) outsider: roster members named | (c) outsider: speaker hit% | random% |
| --- | --- | --- | --- | --- | --- |
| ideas-only | 62.8 | 46.5 | — | — | 20.0 |
| raw | 97.1 | 97.7 | 50/50 (50 by name, 28 by org) | 97.7 | 20.0 |
| +L3 | 65.1 | 43.0 | 3/50 (1 by name, 2 by org) | 1.2 | 20.0 |
| +L4 | 66.3 | 39.5 | 4/50 (1 by name, 3 by org) | 2.3 | 20.0 |

## Role-revealing risk flags (L4 residual)

"strict" = the digest with all flagged claims cut (full-roster attacker).

| transcript | flagged/claims | dropped | strict attack% | strict retention% |
| --- | --- | --- | --- | --- |
| academic | 0/51 | 0 | — | — |
| bookclub | 7/54 | 0 | 66.7 | 94.4 |
| faculty | 4/54 | 0 | 22.2 | 94.4 |
| journalist | 16/52 | 0 | 88.9 | 72.2 |
| medical | 1/47 | 0 | 100.0 | 93.8 |
| ngo | 0/52 | 0 | — | — |
| policy | 5/61 | 0 | 66.7 | 94.4 |
| startup | 1/64 | 0 | 66.7 | 94.4 |
| thinktank | 4/55 | 0 | 44.4 | 94.4 |
| union | 1/49 | 1 | 75.0 | 75.0 |
| ALL | 39/539 | 1 | 65.7 | 89.1 |

## Prototype → Gate v2 (same 7 old transcripts)

Prototype numbers from `server/chatham/eval/results.json` (2026-10-18T01:50:08.143Z, llm). Gate v2 numbers restricted to the same 7 transcripts. Format: prototype → v2.

| config | old transcripts | directLeak% proto→v2 | affilLeak% | quasiLeak% | styleLeak% | fullRoster attack% | namesOnly attack% | outsider named | retention% | gate est$ (total) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ideas-only | 7/7 | 0.0 → 0.0 | 0.0 → 0.0 | 0.0 → 0.0 | 0.0 → 0.0 | 62.7 → 65.3 | 47.5 → 49.2 | — | 0.0 → 0.0 | 0.0000 → 0.0000 |
| raw | 7/7 | 100.0 → 100.0 | 100.0 → 100.0 | 100.0 → 100.0 | 100.0 → 100.0 | 97.5 → 97.5 | 98.3 → 98.3 | 35/35 → 35/35 | 99.2 → 99.2 | 0.0000 → 0.0000 |
| L0+L1 | 7/7 | 1.1 → 2.2 | 100.0 → 100.0 | 100.0 → 100.0 | 100.0 → 100.0 | 72.0 → 73.7 | — | — | 91.5 → 93.2 | 0.0000 → 0.0000 |
| +L2 | 7/7 | 0.0 → 1.1 | 0.0 → 0.0 | 65.0 → 65.0 | 100.0 → 100.0 | 75.4 → 75.4 | — | — | 92.4 → 91.5 | 0.0000 → 0.0000 |
| +L3 | 7/7 | 0.0 → 0.0 | 0.0 → 0.0 | 5.0 → 5.0 | 3.7 → 3.7 | 72.0 → 71.2 | 45.8 → 44.1 | 0/35 → 2/35 | 87.3 → 87.3 | 0.0031 → 0.0047 |
| +L4 | 7/7 | 0.0 → 0.0 | 0.0 → 0.0 | 10.0 → 0.0 | 11.1 → 3.7 | 72.0 → 72.9 | 42.4 → 47.5 | 0/35 → 3/35 | 89.0 → 89.0 | 0.0181 → 0.0216 |

## Mosaic (cross-session linkage)

For each circle the transcript is split into 3 consecutive sessions (thirds of the lines; each gold idea assigned to the session whose raw text matches it best). The full Gate (+L4) runs per session. The full-roster attacker gets (a) each session digest alone, asked only about that session's ideas, and (b) all session digests concatenated, asked about all ideas. Mosaic gain = combined − alone. The knowledge store (core/memory.mjs) receives every session's claims as releases; recallForOutput is queried with the circle title and every gold idea (limit 5) and the union of returned items is attacked again.

| circle | sessions | ideas/claims per session | attack: each digest alone | attack: all digests combined | mosaic gain | outsider named: max alone → combined | memory recallForOutput |
| --- | --- | --- | --- | --- | --- | --- | --- |
| bookclub | 3 | 4i/17c, 3i/22c, 2i/19c | 66.7 (6/9) | 55.6 (5/9) | -11.1 pts | 0 → 0 | 2/50 dropped; 28/58 unique items out; attack 50.0 (4.5/9) |
| policy | 3 | 4i/20c, 2i/20c, 3i/16c | 66.7 (6/9) | 77.8 (7/9) | 11.1 pts | 0 → 0 | 0/50 dropped; 34/56 unique items out; attack 83.3 (7.5/9) |

## Gate v2 per transcript

| transcript | config | publicFactRetention | selfAuthor works + publicName | toneLeak | stancePreserved | flags public-fact / tone |
| --- | --- | --- | --- | --- | --- | --- |
| bookclub | raw | 100.0 (7/7) | 1/1 + 0/0 | 100.0 (5/5) | 100.0 (5/5) | 0 / 0 of 24 |
| bookclub | L0+L1 | 100.0 (7/7) | 1/1 + 0/0 | 100.0 (5/5) | 80.0 (4/5) | 0 / 0 of 66 |
| bookclub | +L2 | 100.0 (7/7) | 0/1 + 0/0 | 100.0 (5/5) | 80.0 (4/5) | 0 / 0 of 66 |
| bookclub | +L3 | 100.0 (7/7) | 0/1 + 0/0 | 0.0 (0/5) | 80.0 (4/5) | 11 / 6 of 50 |
| bookclub | +L4 | 100.0 (7/7) | 0/1 + 0/0 | 0.0 (0/5) | 60.0 (3/5) | 8 / 0 of 54 |
| faculty | raw | 100.0 (7/7) | 1/1 + 0/0 | 100.0 (5/5) | 80.0 (4/5) | 0 / 0 of 24 |
| faculty | L0+L1 | 100.0 (7/7) | 1/1 + 0/0 | 100.0 (5/5) | 100.0 (5/5) | 0 / 0 of 77 |
| faculty | +L2 | 100.0 (7/7) | 0/1 + 0/0 | 100.0 (5/5) | 100.0 (5/5) | 0 / 0 of 77 |
| faculty | +L3 | 100.0 (7/7) | 0/1 + 0/0 | 0.0 (0/5) | 80.0 (4/5) | 5 / 4 of 57 |
| faculty | +L4 | 100.0 (7/7) | 0/1 + 0/0 | 0.0 (0/4) | 80.0 (4/5) | 6 / 2 of 54 |
| policy | raw | 100.0 (7/7) | 1/1 + 1/1 | 100.0 (5/5) | 80.0 (4/5) | 0 / 0 of 23 |
| policy | L0+L1 | 100.0 (7/7) | 1/1 + 0/1 | 100.0 (5/5) | 80.0 (4/5) | 0 / 0 of 66 |
| policy | +L2 | 100.0 (7/7) | 0/1 + 0/1 | 100.0 (5/5) | 80.0 (4/5) | 0 / 0 of 66 |
| policy | +L3 | 85.7 (6/7) | 0/1 + 0/1 | 60.0 (3/5) | 40.0 (2/5) | 6 / 7 of 58 |
| policy | +L4 | 100.0 (7/7) | 0/1 + 0/1 | 0.0 (0/5) | 100.0 (5/5) | 6 / 2 of 61 |

### Gate v2 misses (+L3/+L4)

_Self-author and surface tone strings redacted to 2 chars; public-fact keep strings are public and shown._

| transcript | config | type | id | detail |
| --- | --- | --- | --- | --- |
| bookclub | +L3 | stance | t4 | present=true residual=false; judged support/2 vs gold oppose/2 |
| faculty | +L3 | stance | t4 | present=true residual=false; judged support/1 vs gold doubt/1 |
| policy | +L3 | publicFact missed | f6 | missing: World Health Organization |
| policy | +L3 | tone leak | t1 | present=true residual=true; judged oppose/2 vs gold doubt/2 |
| policy | +L3 | stance | t3 | present=true residual=false; judged doubt/3 vs gold oppose/3 |
| policy | +L3 | tone leak | t4 | present=true residual=true; judged oppose/2 vs gold doubt/2 |
| policy | +L3 | tone leak | t5 | present=true residual=true; judged doubt/2 vs gold doubt/1 |
| bookclub | +L4 | stance | t3 | present=true residual=false; judged doubt/2 vs gold oppose/3 |
| bookclub | +L4 | stance | t4 | present=true residual=false; judged support/2 vs gold oppose/2 |
| faculty | +L4 | stance | t4 | present=false residual=false; judged absent/1 vs gold doubt/1 |
| journalist | +L3 | outsider name match | p3 | guess "zl…" |
| policy | +L3 | outsider org match | p4 | guess "某市/区住建或发改部门（“滨江”口径）" |
| union | +L3 | outsider org match | p3 | guess "美团" |
| journalist | +L4 | outsider name match | p3 | guess "zl…" |
| policy | +L4 | outsider org match | p4 | guess "滨江（区/市）政府或相关部门" |
| thinktank | +L4 | outsider org match | p3 | guess "中国钢铁工业协会 (China Iron and Steel Association, CISA)" |
| thinktank | +L4 | outsider org match | p5 | guess "生态环境部/国家应对气候变化战略研究和国际合作中心 (NCSC)" |

## How to read this

- **ideas-only** is a floor: the attacker gets the roster and the bare gold idea texts, with no digest. No de-identification that keeps the idea can push the full-roster attack much below that floor.
- **(a) full roster with org/title** is an insider. **(c) outsider** is the outward threat: the digest must not reveal who attended.
- Gate v2 deliberately keeps public-world facts (named authors, laws, public bodies). The gold `org`/`title` identifiers in all 10 transcripts are participant-owned (owner p1..p5), so affilLeak keeps its meaning: any of them in the digest is a real leak.
- Attacker, gate and judges all use the same model family (deepseek-flash). n is small (10 synthetic transcripts; 15 tone markers, 21 public facts, 3 self-authored works): one marker ≈ 6.7 pts of toneLeak/stancePreserved. Judge noise matters.

## Per transcript

| transcript | config | directLeak% | affilLeak% | quasiLeak% | styleLeak% | attackAcc% | randomBaseline% | retention% | latencyMs | tokens | est$ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| academic | ideas-only | 0.0 (0/12) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/5) | 50.0 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| academic | raw | 100.0 (12/12) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (5/5) | 100.0 | 20.0 | 100.0 | 1 | 0 | 0.00000 |
| academic | L0+L1 | 8.3 (1/12) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (5/5) | 50.0 | 20.0 | 100.0 | 69 | 0 | 0.00000 |
| academic | +L2 | 8.3 (1/12) | 0.0 (0/2) | 100.0 (3/3) | 100.0 (5/5) | 56.3 | 20.0 | 100.0 | 96 | 0 | 0.00000 |
| academic | +L3 | 0.0 (0/12) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/5) | 43.8 | 20.0 | 93.8 | 6248 | 4240 | 0.00060 |
| academic | +L4 | 0.0 (0/12) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/5) | 50.0 | 20.0 | 93.8 | 29683 | 16860 | 0.00286 |
| bookclub | ideas-only | 0.0 (0/12) | 0.0 (0/3) | 0.0 (0/2) | 0.0 (0/6) | 55.6 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| bookclub | raw | 100.0 (12/12) | 100.0 (3/3) | 100.0 (2/2) | 100.0 (6/6) | 100.0 | 20.0 | 100.0 | 4 | 0 | 0.00000 |
| bookclub | L0+L1 | 8.3 (1/12) | 100.0 (3/3) | 100.0 (2/2) | 100.0 (6/6) | 50.0 | 20.0 | 94.4 | 45 | 0 | 0.00000 |
| bookclub | +L2 | 8.3 (1/12) | 0.0 (0/3) | 100.0 (2/2) | 100.0 (6/6) | 55.6 | 20.0 | 100.0 | 76 | 0 | 0.00000 |
| bookclub | +L3 | 0.0 (0/12) | 0.0 (0/3) | 0.0 (0/2) | 0.0 (0/6) | 61.1 | 20.0 | 94.4 | 7738 | 4703 | 0.00069 |
| bookclub | +L4 | 0.0 (0/12) | 0.0 (0/3) | 0.0 (0/2) | 0.0 (0/6) | 72.2 | 20.0 | 94.4 | 30157 | 17577 | 0.00280 |
| faculty | ideas-only | 0.0 (0/11) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/5) | 38.9 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| faculty | raw | 100.0 (11/11) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (5/5) | 88.9 | 20.0 | 94.4 | 6 | 0 | 0.00000 |
| faculty | L0+L1 | 9.1 (1/11) | 100.0 (2/2) | 66.7 (2/3) | 100.0 (5/5) | 38.9 | 20.0 | 100.0 | 32 | 0 | 0.00000 |
| faculty | +L2 | 0.0 (0/11) | 0.0 (0/2) | 66.7 (2/3) | 100.0 (5/5) | 27.8 | 20.0 | 100.0 | 52 | 0 | 0.00000 |
| faculty | +L3 | 0.0 (0/11) | 0.0 (0/2) | 66.7 (2/3) | 0.0 (0/5) | 11.1 | 20.0 | 88.9 | 8061 | 4784 | 0.00072 |
| faculty | +L4 | 0.0 (0/11) | 0.0 (0/2) | 33.3 (1/3) | 0.0 (0/5) | 11.1 | 20.0 | 94.4 | 27774 | 16050 | 0.00258 |
| journalist | ideas-only | 0.0 (0/13) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/4) | 77.8 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| journalist | raw | 100.0 (13/13) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (4/4) | 100.0 | 20.0 | 100.0 | 10 | 0 | 0.00000 |
| journalist | L0+L1 | 0.0 (0/13) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (4/4) | 88.9 | 20.0 | 83.3 | 27 | 0 | 0.00000 |
| journalist | +L2 | 0.0 (0/13) | 0.0 (0/2) | 66.7 (2/3) | 100.0 (4/4) | 88.9 | 20.0 | 88.9 | 33 | 0 | 0.00000 |
| journalist | +L3 | 0.0 (0/13) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/4) | 88.9 | 20.0 | 88.9 | 7709 | 4370 | 0.00066 |
| journalist | +L4 | 0.0 (0/13) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/4) | 77.8 | 20.0 | 88.9 | 34470 | 20275 | 0.00334 |
| medical | ideas-only | 0.0 (0/15) | 0.0 (0/2) | 0.0 (0/2) | 0.0 (0/3) | 93.8 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| medical | raw | 100.0 (15/15) | 100.0 (2/2) | 100.0 (2/2) | 100.0 (3/3) | 100.0 | 20.0 | 100.0 | 0 | 0 | 0.00000 |
| medical | L0+L1 | 0.0 (0/15) | 100.0 (2/2) | 100.0 (2/2) | 100.0 (3/3) | 87.5 | 20.0 | 100.0 | 14 | 0 | 0.00000 |
| medical | +L2 | 0.0 (0/15) | 0.0 (0/2) | 50.0 (1/2) | 100.0 (3/3) | 87.5 | 20.0 | 100.0 | 19 | 0 | 0.00000 |
| medical | +L3 | 0.0 (0/15) | 0.0 (0/2) | 0.0 (0/2) | 33.3 (1/3) | 93.8 | 20.0 | 93.8 | 7020 | 4425 | 0.00063 |
| medical | +L4 | 0.0 (0/15) | 0.0 (0/2) | 0.0 (0/2) | 33.3 (1/3) | 93.8 | 20.0 | 100.0 | 31188 | 18401 | 0.00290 |
| ngo | ideas-only | 0.0 (0/13) | 0.0 (0/3) | 0.0 (0/3) | 0.0 (0/3) | 81.3 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| ngo | raw | 100.0 (13/13) | 100.0 (3/3) | 100.0 (3/3) | 100.0 (3/3) | 100.0 | 20.0 | 100.0 | 0 | 0 | 0.00000 |
| ngo | L0+L1 | 0.0 (0/13) | 100.0 (3/3) | 100.0 (3/3) | 100.0 (3/3) | 75.0 | 20.0 | 93.8 | 12 | 0 | 0.00000 |
| ngo | +L2 | 0.0 (0/13) | 0.0 (0/3) | 66.7 (2/3) | 100.0 (3/3) | 87.5 | 20.0 | 87.5 | 16 | 0 | 0.00000 |
| ngo | +L3 | 0.0 (0/13) | 0.0 (0/3) | 0.0 (0/3) | 0.0 (0/3) | 87.5 | 20.0 | 87.5 | 8310 | 4698 | 0.00071 |
| ngo | +L4 | 0.0 (0/13) | 0.0 (0/3) | 0.0 (0/3) | 0.0 (0/3) | 87.5 | 20.0 | 75.0 | 29941 | 17424 | 0.00281 |
| policy | ideas-only | 0.0 (0/11) | 0.0 (0/4) | 0.0 (0/3) | 0.0 (0/4) | 77.8 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| policy | raw | 100.0 (11/11) | 100.0 (4/4) | 100.0 (3/3) | 100.0 (4/4) | 100.0 | 20.0 | 100.0 | 0 | 0 | 0.00000 |
| policy | L0+L1 | 18.2 (2/11) | 100.0 (4/4) | 100.0 (3/3) | 100.0 (4/4) | 88.9 | 20.0 | 94.4 | 11 | 0 | 0.00000 |
| policy | +L2 | 9.1 (1/11) | 0.0 (0/4) | 100.0 (3/3) | 100.0 (4/4) | 83.3 | 20.0 | 94.4 | 19 | 0 | 0.00000 |
| policy | +L3 | 0.0 (0/11) | 0.0 (0/4) | 0.0 (0/3) | 25.0 (1/4) | 83.3 | 20.0 | 94.4 | 8161 | 4742 | 0.00071 |
| policy | +L4 | 0.0 (0/11) | 0.0 (0/4) | 0.0 (0/3) | 25.0 (1/4) | 72.2 | 20.0 | 94.4 | 34058 | 19519 | 0.00320 |
| startup | ideas-only | 0.0 (0/12) | 0.0 (0/3) | 0.0 (0/2) | 0.0 (0/5) | 66.7 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| startup | raw | 100.0 (12/12) | 100.0 (3/3) | 100.0 (2/2) | 100.0 (5/5) | 94.4 | 20.0 | 100.0 | 0 | 0 | 0.00000 |
| startup | L0+L1 | 8.3 (1/12) | 100.0 (3/3) | 100.0 (2/2) | 100.0 (5/5) | 88.9 | 20.0 | 94.4 | 11 | 0 | 0.00000 |
| startup | +L2 | 0.0 (0/12) | 0.0 (0/3) | 100.0 (2/2) | 100.0 (5/5) | 83.3 | 20.0 | 94.4 | 24 | 0 | 0.00000 |
| startup | +L3 | 0.0 (0/12) | 0.0 (0/3) | 50.0 (1/2) | 0.0 (0/5) | 72.2 | 20.0 | 94.4 | 7575 | 4722 | 0.00070 |
| startup | +L4 | 0.0 (0/12) | 0.0 (0/3) | 0.0 (0/2) | 0.0 (0/5) | 77.8 | 20.0 | 94.4 | 34714 | 21015 | 0.00346 |
| thinktank | ideas-only | 0.0 (0/12) | 0.0 (0/2) | 0.0 (0/4) | 0.0 (0/4) | 27.8 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| thinktank | raw | 100.0 (12/12) | 100.0 (2/2) | 100.0 (4/4) | 100.0 (4/4) | 88.9 | 20.0 | 94.4 | 0 | 0 | 0.00000 |
| thinktank | L0+L1 | 0.0 (0/12) | 100.0 (2/2) | 100.0 (4/4) | 100.0 (4/4) | 50.0 | 20.0 | 94.4 | 9 | 0 | 0.00000 |
| thinktank | +L2 | 0.0 (0/12) | 0.0 (0/2) | 50.0 (2/4) | 100.0 (4/4) | 44.4 | 20.0 | 94.4 | 22 | 0 | 0.00000 |
| thinktank | +L3 | 0.0 (0/12) | 0.0 (0/2) | 0.0 (0/4) | 0.0 (0/4) | 33.3 | 20.0 | 94.4 | 7979 | 4748 | 0.00071 |
| thinktank | +L4 | 0.0 (0/12) | 0.0 (0/2) | 0.0 (0/4) | 0.0 (0/4) | 38.9 | 20.0 | 94.4 | 31503 | 18095 | 0.00293 |
| union | ideas-only | 0.0 (0/14) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/3) | 62.5 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| union | raw | 100.0 (14/14) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (3/3) | 100.0 | 20.0 | 100.0 | 0 | 0 | 0.00000 |
| union | L0+L1 | 0.0 (0/14) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (3/3) | 75.0 | 20.0 | 87.5 | 12 | 0 | 0.00000 |
| union | +L2 | 0.0 (0/14) | 0.0 (0/2) | 33.3 (1/3) | 100.0 (3/3) | 81.3 | 20.0 | 75.0 | 18 | 0 | 0.00000 |
| union | +L3 | 0.0 (0/14) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/3) | 81.3 | 20.0 | 56.3 | 7709 | 4531 | 0.00067 |
| union | +L4 | 0.0 (0/14) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/3) | 87.5 | 20.0 | 75.0 | 34024 | 20450 | 0.00332 |

## Leaked identifiers per config

_Leaked strings are redacted to their first 2 characters._

### ideas-only (0 leaked)

_none_

### raw (220 leaked)

| transcript | category | kind | owner | identifier |
| --- | --- | --- | --- | --- |
| academic | direct | name | p3 | Th… |
| academic | direct | name | p1 | Ma… |
| academic | direct | name | third | Pr… |
| academic | direct | name | third | Hu… |
| academic | direct | url | p3 | gi… |
| academic | direct | email | p5 | kz… |
| academic | direct | phone | p5 | +1… |
| academic | direct | handle | p4 | @t… |
| academic | direct | address | p4 | Un… |
| academic | direct | phone | p4 | +4… |
| academic | direct | email | p3 | xl… |
| academic | direct | date | p3 | I … |
| academic | affil | title | p5 | As… |
| academic | affil | title | p1 | As… |
| academic | quasi | quasi | p4 | my… |
| academic | quasi | quasi | p5 | si… |
| academic | quasi | quasi | p1 | I'… |
| academic | style | style | p1 | To… |
| academic | style | style | p2 | Le… |
| academic | style | style | p3 | If… |
| academic | style | style | p5 | To… |
| academic | style | style | p4 | Co… |
| bookclub | direct | phone | p4 | 18… |
| bookclub | direct | phone | third | +8… |
| bookclub | direct | email | p5 | pe… |
| bookclub | direct | email | p1 | sh… |
| bookclub | direct | url | p5 | xi… |
| bookclub | direct | handle | p4 | @冬… |
| bookclub | direct | name | p2 | 郭总… |
| bookclub | direct | name | p3 | 苏老… |
| bookclub | direct | name | p1 | 沈老… |
| bookclub | direct | name | third | 小罗… |
| bookclub | direct | address | p3 | 杭州… |
| bookclub | direct | date | p4 | 我上… |
| bookclub | affil | title | p1 | 我在… |
| bookclub | affil | org | p2 | 我作… |
| bookclub | affil | org | p5 | 我们… |
| bookclub | quasi | quasi | p4 | 我去… |
| bookclub | quasi | quasi | p3 | 我经… |
| bookclub | style | style | p1 | 怎么… |
| bookclub | style | style | p2 | 讲句… |
| bookclub | style | style | p3 | 说到… |
| bookclub | style | style | p4 | 老鼻… |
| bookclub | style | style | p5 | 呵呵… |
| bookclub | style | style | p5 | 可真… |
| faculty | direct | phone | p1 | 01… |
| faculty | direct | email | p1 | e.… |
| faculty | direct | email | p4 | d.… |
| faculty | direct | url | p4 | ha… |
| faculty | direct | handle | p5 | @p… |
| faculty | direct | name | p2 | Ma… |
| faculty | direct | name | p3 | In… |
| faculty | direct | name | p5 | Pr… |
| faculty | direct | name | third | Cl… |
| faculty | direct | address | p5 | Ro… |
| faculty | direct | date | p5 | I'… |
| faculty | affil | title | p1 | I'… |
| faculty | affil | org | p4 | Fr… |
| faculty | quasi | quasi | p4 | af… |
| faculty | quasi | quasi | p5 | 14… |
| faculty | quasi | quasi | p3 | My… |
| faculty | style | style | p1 | Fo… |
| faculty | style | style | p2 | Wi… |
| faculty | style | style | p3 | Sp… |
| faculty | style | style | p5 | I'… |
| faculty | style | style | p4 | Qu… |
| journalist | direct | phone | p3 | 13… |
| journalist | direct | phone | p4 | +1… |
| journalist | direct | email | p3 | zl… |
| journalist | direct | email | p1 | ml… |
| journalist | direct | url | p3 | gi… |
| journalist | direct | url | p1 | we… |
| journalist | direct | handle | p5 | @s… |
| journalist | direct | name | p3 | 赵工… |
| journalist | direct | name | p3 | Th… |
| journalist | direct | name | p4 | 黄律… |
| journalist | direct | name | third | 刘振… |
| journalist | direct | address | third | 苏州… |
| journalist | direct | date | p3 | 我2… |
| journalist | affil | org | p3 | 我们… |
| journalist | affil | title | p4 | as… |
| journalist | quasi | quasi | p3 | 我老… |
| journalist | quasi | quasi | p1 | I … |
| journalist | quasi | quasi | p5 | I … |
| journalist | style | style | p3 | 说白… |
| journalist | style | style | p2 | Bo… |
| journalist | style | style | p4 | To… |
| journalist | style | style | p5 | Le… |
| medical | direct | name | third | 赵立… |
| medical | direct | idcard | third | 11… |
| medical | direct | date | third | 9月… |
| medical | direct | phone | third | 13… |
| medical | direct | address | third | 北京… |
| medical | direct | name | third | 刘广… |
| medical | affil | org | p1 | 中国… |
| medical | direct | handle | p1 | @胸… |
| medical | direct | name | p1 | 陈主… |
| medical | style | style | p1 | 说白… |
| medical | direct | name | p2 | Gr… |
| medical | direct | email | p2 | li… |
| medical | style | style | p2 | 坦率… |
| medical | direct | name | p3 | 周主… |
| medical | affil | title | p3 | 作为… |
| medical | direct | url | p3 | gi… |
| medical | style | style | p3 | 从剂… |
| medical | quasi | quasi | p4 | 我上… |
| medical | direct | url | p4 | we… |
| medical | direct | date | p5 | 我8… |
| medical | quasi | quasi | p5 | 我那… |
| medical | direct | phone | p5 | +8… |
| ngo | direct | phone | p2 | 13… |
| ngo | direct | phone | p5 | +1… |
| ngo | direct | email | p3 | he… |
| ngo | direct | email | p4 | mc… |
| ngo | direct | url | p2 | gi… |
| ngo | direct | url | third | we… |
| ngo | direct | handle | p1 | @l… |
| ngo | direct | idcard | third | 52… |
| ngo | direct | name | third | 杨秀… |
| ngo | direct | name | p4 | 陈博… |
| ngo | direct | name | p3 | 何会… |
| ngo | direct | address | third | 贵州… |
| ngo | direct | date | p3 | 4月… |
| ngo | affil | title | p3 | 作为… |
| ngo | affil | org | p4 | as… |
| ngo | affil | org | p5 | I … |
| ngo | quasi | quasi | p1 | 我当… |
| ngo | quasi | quasi | p4 | My… |
| ngo | quasi | quasi | p2 | 我上… |
| ngo | style | style | p1 | 说到… |
| ngo | style | style | p3 | 账面… |
| ngo | style | style | p5 | Fr… |
| policy | direct | phone | p3 | 13… |
| policy | direct | email | p1 | sh… |
| policy | direct | email | p2 | h.… |
| policy | direct | url | p3 | qi… |
| policy | direct | handle | p5 | @海… |
| policy | direct | name | p1 | 邵主… |
| policy | direct | name | p3 | Da… |
| policy | direct | name | p4 | Th… |
| policy | direct | name | p5 | 梁先… |
| policy | direct | address | p4 | 海湾… |
| policy | direct | date | p1 | 我去… |
| policy | affil | title | p1 | 我在… |
| policy | affil | org | p3 | 我们… |
| policy | affil | org | p2 | In… |
| policy | affil | org | p4 | 我们… |
| policy | quasi | quasi | p5 | 我细… |
| policy | quasi | quasi | p4 | 我自… |
| policy | quasi | quasi | p1 | 我下… |
| policy | style | style | p2 | Fr… |
| policy | style | style | p3 | To… |
| policy | style | style | p4 | 从数… |
| policy | style | style | p5 | 老实… |
| startup | style | style | p1 | 说白… |
| startup | direct | name | p5 | Mi… |
| startup | direct | name | p1 | Si… |
| startup | affil | org | p5 | As… |
| startup | style | style | p2 | 坦率… |
| startup | style | style | p4 | Ho… |
| startup | style | style | p3 | 本质… |
| startup | direct | url | p3 | gi… |
| startup | direct | date | p3 | 我7… |
| startup | style | style | p5 | Bo… |
| startup | direct | name | third | 李处… |
| startup | direct | phone | third | 13… |
| startup | direct | name | p4 | 婷婷… |
| startup | affil | org | p4 | 以前… |
| startup | quasi | quasi | p4 | 我做… |
| startup | direct | email | third | je… |
| startup | direct | phone | p5 | +1… |
| startup | direct | handle | third | @p… |
| startup | direct | address | p2 | 浦东… |
| startup | affil | title | p1 | 作为… |
| startup | quasi | quasi | p3 | 我的… |
| startup | direct | email | p2 | he… |
| thinktank | direct | address | p1 | 东城… |
| thinktank | direct | url | p1 | we… |
| thinktank | direct | handle | p1 | @z… |
| thinktank | quasi | quasi | p1 | 我女… |
| thinktank | direct | date | p2 | 我3… |
| thinktank | quasi | quasi | p2 | 之前… |
| thinktank | style | style | p2 | 坦率… |
| thinktank | affil | title | p3 | 作为… |
| thinktank | direct | phone | p3 | 13… |
| thinktank | direct | name | p3 | 马总… |
| thinktank | style | style | p3 | 说白… |
| thinktank | direct | name | third | 李卫… |
| thinktank | affil | title | p4 | as… |
| thinktank | quasi | quasi | p4 | I … |
| thinktank | direct | email | p4 | sa… |
| thinktank | direct | phone | p4 | +8… |
| thinktank | direct | name | p4 | Th… |
| thinktank | style | style | p4 | Fr… |
| thinktank | direct | url | p5 | gi… |
| thinktank | quasi | quasi | p5 | 我上… |
| thinktank | direct | name | p5 | Dr… |
| thinktank | style | style | p5 | 从计… |
| union | direct | phone | p1 | 13… |
| union | direct | phone | p2 | +8… |
| union | direct | phone | third | +1… |
| union | direct | email | p2 | zh… |
| union | direct | email | p5 | li… |
| union | direct | idcard | third | 44… |
| union | direct | url | p5 | gi… |
| union | direct | url | p3 | we… |
| union | direct | handle | p3 | @深… |
| union | direct | name | p2 | 周律… |
| union | direct | name | p3 | 老马… |
| union | direct | name | third | Em… |
| union | direct | address | p4 | 龙华… |
| union | direct | date | p4 | 我2… |
| union | affil | org | p2 | 我作… |
| union | affil | title | p3 | 我在… |
| union | quasi | quasi | p1 | 我以… |
| union | quasi | quasi | p5 | 我是… |
| union | quasi | quasi | p4 | 我老… |
| union | style | style | p1 | 说白… |
| union | style | style | p2 | 从法… |
| union | style | style | p3 | 我跟… |

### L0+L1 (100 leaked)

| transcript | category | kind | owner | identifier |
| --- | --- | --- | --- | --- |
| academic | direct | name | third | Pr… |
| academic | affil | title | p5 | As… |
| academic | affil | title | p1 | As… |
| academic | quasi | quasi | p4 | my… |
| academic | quasi | quasi | p5 | si… |
| academic | quasi | quasi | p1 | I'… |
| academic | style | style | p1 | To… |
| academic | style | style | p2 | Le… |
| academic | style | style | p3 | If… |
| academic | style | style | p5 | To… |
| academic | style | style | p4 | Co… |
| bookclub | direct | name | third | 小罗… |
| bookclub | affil | title | p1 | 我在… |
| bookclub | affil | org | p2 | 我作… |
| bookclub | affil | org | p5 | 我们… |
| bookclub | quasi | quasi | p4 | 我去… |
| bookclub | quasi | quasi | p3 | 我经… |
| bookclub | style | style | p1 | 怎么… |
| bookclub | style | style | p2 | 讲句… |
| bookclub | style | style | p3 | 说到… |
| bookclub | style | style | p4 | 老鼻… |
| bookclub | style | style | p5 | 呵呵… |
| bookclub | style | style | p5 | 可真… |
| faculty | direct | date | p5 | I'… |
| faculty | affil | title | p1 | I'… |
| faculty | affil | org | p4 | Fr… |
| faculty | quasi | quasi | p4 | af… |
| faculty | quasi | quasi | p5 | 14… |
| faculty | style | style | p1 | Fo… |
| faculty | style | style | p2 | Wi… |
| faculty | style | style | p3 | Sp… |
| faculty | style | style | p5 | I'… |
| faculty | style | style | p4 | Qu… |
| journalist | affil | org | p3 | 我们… |
| journalist | affil | title | p4 | as… |
| journalist | quasi | quasi | p3 | 我老… |
| journalist | quasi | quasi | p1 | I … |
| journalist | quasi | quasi | p5 | I … |
| journalist | style | style | p3 | 说白… |
| journalist | style | style | p2 | Bo… |
| journalist | style | style | p4 | To… |
| journalist | style | style | p5 | Le… |
| medical | affil | org | p1 | 中国… |
| medical | style | style | p1 | 说白… |
| medical | style | style | p2 | 坦率… |
| medical | affil | title | p3 | 作为… |
| medical | style | style | p3 | 从剂… |
| medical | quasi | quasi | p4 | 我上… |
| medical | quasi | quasi | p5 | 我那… |
| ngo | affil | title | p3 | 作为… |
| ngo | affil | org | p4 | as… |
| ngo | affil | org | p5 | I … |
| ngo | quasi | quasi | p1 | 我当… |
| ngo | quasi | quasi | p4 | My… |
| ngo | quasi | quasi | p2 | 我上… |
| ngo | style | style | p1 | 说到… |
| ngo | style | style | p3 | 账面… |
| ngo | style | style | p5 | Fr… |
| policy | direct | address | p4 | 海湾… |
| policy | direct | date | p1 | 我去… |
| policy | affil | title | p1 | 我在… |
| policy | affil | org | p3 | 我们… |
| policy | affil | org | p2 | In… |
| policy | affil | org | p4 | 我们… |
| policy | quasi | quasi | p5 | 我细… |
| policy | quasi | quasi | p4 | 我自… |
| policy | quasi | quasi | p1 | 我下… |
| policy | style | style | p2 | Fr… |
| policy | style | style | p3 | To… |
| policy | style | style | p4 | 从数… |
| policy | style | style | p5 | 老实… |
| startup | style | style | p1 | 说白… |
| startup | affil | org | p5 | As… |
| startup | style | style | p2 | 坦率… |
| startup | style | style | p4 | Ho… |
| startup | style | style | p3 | 本质… |
| startup | style | style | p5 | Bo… |
| startup | direct | name | third | 李处… |
| startup | affil | org | p4 | 以前… |
| startup | quasi | quasi | p4 | 我做… |
| startup | affil | title | p1 | 作为… |
| startup | quasi | quasi | p3 | 我的… |
| thinktank | quasi | quasi | p1 | 我女… |
| thinktank | quasi | quasi | p2 | 之前… |
| thinktank | style | style | p2 | 坦率… |
| thinktank | affil | title | p3 | 作为… |
| thinktank | style | style | p3 | 说白… |
| thinktank | affil | title | p4 | as… |
| thinktank | quasi | quasi | p4 | I … |
| thinktank | style | style | p4 | Fr… |
| thinktank | quasi | quasi | p5 | 我上… |
| thinktank | style | style | p5 | 从计… |
| union | affil | org | p2 | 我作… |
| union | affil | title | p3 | 我在… |
| union | quasi | quasi | p1 | 我以… |
| union | quasi | quasi | p5 | 我是… |
| union | quasi | quasi | p4 | 我老… |
| union | style | style | p1 | 说白… |
| union | style | style | p2 | 从法… |
| union | style | style | p3 | 我跟… |

### +L2 (65 leaked)

| transcript | category | kind | owner | identifier |
| --- | --- | --- | --- | --- |
| academic | direct | name | third | Pr… |
| academic | quasi | quasi | p4 | my… |
| academic | quasi | quasi | p5 | si… |
| academic | quasi | quasi | p1 | I'… |
| academic | style | style | p1 | To… |
| academic | style | style | p2 | Le… |
| academic | style | style | p3 | If… |
| academic | style | style | p5 | To… |
| academic | style | style | p4 | Co… |
| bookclub | direct | name | third | 小罗… |
| bookclub | quasi | quasi | p4 | 我去… |
| bookclub | quasi | quasi | p3 | 我经… |
| bookclub | style | style | p1 | 怎么… |
| bookclub | style | style | p2 | 讲句… |
| bookclub | style | style | p3 | 说到… |
| bookclub | style | style | p4 | 老鼻… |
| bookclub | style | style | p5 | 呵呵… |
| bookclub | style | style | p5 | 可真… |
| faculty | quasi | quasi | p4 | af… |
| faculty | quasi | quasi | p5 | 14… |
| faculty | style | style | p1 | Fo… |
| faculty | style | style | p2 | Wi… |
| faculty | style | style | p3 | Sp… |
| faculty | style | style | p5 | I'… |
| faculty | style | style | p4 | Qu… |
| journalist | quasi | quasi | p3 | 我老… |
| journalist | quasi | quasi | p1 | I … |
| journalist | style | style | p3 | 说白… |
| journalist | style | style | p2 | Bo… |
| journalist | style | style | p4 | To… |
| journalist | style | style | p5 | Le… |
| medical | style | style | p1 | 说白… |
| medical | style | style | p2 | 坦率… |
| medical | style | style | p3 | 从剂… |
| medical | quasi | quasi | p5 | 我那… |
| ngo | quasi | quasi | p4 | My… |
| ngo | quasi | quasi | p2 | 我上… |
| ngo | style | style | p1 | 说到… |
| ngo | style | style | p3 | 账面… |
| ngo | style | style | p5 | Fr… |
| policy | direct | date | p1 | 我去… |
| policy | quasi | quasi | p5 | 我细… |
| policy | quasi | quasi | p4 | 我自… |
| policy | quasi | quasi | p1 | 我下… |
| policy | style | style | p2 | Fr… |
| policy | style | style | p3 | To… |
| policy | style | style | p4 | 从数… |
| policy | style | style | p5 | 老实… |
| startup | style | style | p1 | 说白… |
| startup | style | style | p2 | 坦率… |
| startup | style | style | p4 | Ho… |
| startup | style | style | p3 | 本质… |
| startup | style | style | p5 | Bo… |
| startup | quasi | quasi | p4 | 我做… |
| startup | quasi | quasi | p3 | 我的… |
| thinktank | quasi | quasi | p1 | 我女… |
| thinktank | style | style | p2 | 坦率… |
| thinktank | style | style | p3 | 说白… |
| thinktank | quasi | quasi | p4 | I … |
| thinktank | style | style | p4 | Fr… |
| thinktank | style | style | p5 | 从计… |
| union | quasi | quasi | p4 | 我老… |
| union | style | style | p1 | 说白… |
| union | style | style | p2 | 从法… |
| union | style | style | p3 | 我跟… |

### +L3 (5 leaked)

| transcript | category | kind | owner | identifier |
| --- | --- | --- | --- | --- |
| faculty | quasi | quasi | p4 | af… |
| faculty | quasi | quasi | p5 | 14… |
| medical | style | style | p3 | 从剂… |
| policy | style | style | p4 | 从数… |
| startup | quasi | quasi | p4 | 我做… |

### +L4 (3 leaked)

| transcript | category | kind | owner | identifier |
| --- | --- | --- | --- | --- |
| faculty | quasi | quasi | p5 | 14… |
| medical | style | style | p3 | 从剂… |
| policy | style | style | p4 | 从数… |

## Analysis (hand-written after the final run on 2026-10-18; a re-run regenerates the sections above but not this one)

**Targets for +L4 over all 10 transcripts:** publicFactRetention 100% (21/21) ✅, toneLeak 0% (0/14) ✅, selfAuthorLeak 0 (works 0/3, publicName 0/1) ✅, direct and affil leaks 0% ✅, idea retention 90.7% ✅. Two targets were missed: **stancePreserved 80.0% (12/15)**, against a target of ≥85%, and **outsider named 4/50**, against a target of 0.

**stancePreserved (12/15).** The three misses are all bookclub or faculty:
- bookclub t3 (oppose/3): judged as doubt/2 ("表示明确怀疑"). L3 picked the doubt verb even though the speaker rejects the claim.
- bookclub t4 (oppose/2): judged as support/2. The publisher's defensive rebuttal ("并非不愿支付，而是市场无法承担") came out as an affirmative statement, so the judge read it as support for the speaker's own position, not opposition to the accusation. The gold direction is relative to the *target*, and the digest does not name that target.
- faculty t4 (doubt/1): the claim is absent. This is a mild ironic aside ("another policy review in twelve months"), and the gate merged or dropped it.

Over the 4 iteration runs on the three new transcripts, stance scored 46.7 → 86.7 → 86.7 → 80.0%. The final score of 80.0 is one marker below the iteration-2/3 level. With n=15, one marker is 6.7 pts, so 80 vs 86.7 is within run-to-run noise from the gate and the judge. The prompt fix took this metric from about 47% to the low/mid 80s, and it now sits right around the target, not reliably above it.

**Outsider (4/50 roster members named for +L4; prototype 0/35 on the old 7):**
- journalist p3, by name: the digest keeps the PDF metadata author string "zlei". This is a document handle that L1 does not recognise as a handle. L4 flagged that claim as role-revealing, but it still went out in the main digest.
- policy p4, by org: the outsider guessed "滨江（区/市）政府" and the scorer matched the fragment "滨江" against 滨江大学. The guess is about the city, not about the participant's university. I count this as a scorer false positive (city-name overlap).
- thinktank p3/p5, by org: the outsider guessed 中国钢铁工业协会 and 生态环境部/NCSC from the topic alone (a CBAM/steel discussion). Neither name appears in the digest. This is world-knowledge inference, so this kind of outsider cannot score 0 here even with a perfect gate.

The one real gate miss is "zlei". It belongs in L1 (handle-like tokens in document metadata), not in an L3 prompt. I did not touch L1 because it is outside my remit.

**Insider attack.** Full roster: 66.3%. Names-only: 39.5%. Ideas-only floor: 62.8%. Random: 20%. On the old 7 transcripts, the full-roster attack is 72.9% vs 72.0% in the prototype, and names-only is 47.5% vs 42.4%. Both are within the noise of 2 attack samples and leave no headroom above the floor. Keeping public facts did not measurably help the insider. It also does not change the full-roster figure: anyone who knows the roster can still attribute ideas from their content.

**Prototype comparison.** On the old 7 transcripts Gate v2 matches or beats the prototype: direct and affil both 0, quasi 10.0 → 0.0, style 11.1 → 3.7, retention 89.0 = 89.0 (the per-transcript sums differ; the pooled totals coincide). The gate costs $0.0181 → $0.0216 for the 7 transcripts.

**Mosaic.** Each circle was split into 3 sessions:
- bookclub: alone 66.7% vs combined 55.6% (−11 pts).
- policy: alone 66.7% vs combined 77.8% (+11 pts).

One idea is 11 pts, so neither difference shows a mosaic effect at this n. Concatenating digests gives the attacker no cross-session handle, because each digest has no speaker labels to link. The outsider named 0 for both circles, alone and combined. `core/memory.mjs` `recallForOutput` dropped 2 of 50 candidates for bookclub and 0 of 50 for policy. An attacker on the recalled union scored 50.0% and 83.3%, the same range as the plain digests. The memory-level mosaic check rarely fires on this data.

**affilLeak gold.** Every org/title gold identifier in all 10 transcripts is participant-owned self-affiliation ("我们BMS验证组", "我在用友那几年", "英国驻华使馆经济处一等秘书"…). None is a third-party public org that Gate v2 would legitimately keep, so affilLeak keeps its meaning. 用友 and the British Embassy are public organisations, but here they appear only as the speaker's own employer, so they remain leaks.

**Prompt changes made in this phase** (`core/gate/l3.mjs`, `core/gate/l4.mjs`):
1. L3 rule 11: keep public names exactly as written, with no translation or expansion. A translation may be added in parentheses. Before this change the digest rewrote "World Health Organization" as 世界卫生组织, "EU AI Act" as 《人工智能法案》 and 住建部 as 住房和城乡建设部, and policy scored 3/7 public facts. Pooled public facts went 81.0% → 95.2% (iteration) → 100% (final).
2. L3 rule 12: added a stance vocabulary. oppose = rejects or argues against; doubt = questions without rejecting; strength 1–3 without inflation. Each stance must stay in the same claim as its reasons, numbers and concrete target. Before this, everything collapsed into "表示怀疑" (doubt/3), and stance went 46.7% → 86.7%.
3. L3 rule 3: institutional-position cues are generalised: reporting lines (向省发改委汇报), "不代表市里正式立场", offers to fund or sign on behalf of an organisation, and short references to one's own unit ("funded by the Centre", "平台这边"). This took outsider org hits on the new transcripts from 1–2 to 0.
4. L4 GENERALISER: the same oppose/doubt and strength guidance, plus "public names verbatim".
5. Eval judge (`eval/judge.mjs`): the tone judge's stance step now carries the same oppose/doubt/support definitions, so the judge and the gate use one vocabulary. Caveat: this aligns the definitions, but the gate and the judge are the same model family.

`node --test server/anonym-agent/test/` passes (81/81) after the edits.

**Runtime / cost of the final run:** wall time 573 s. Gate tokens 288,793 (≈ $0.045). Judge and attacker tokens 627,881 (≈ $0.068). Prices are assumed to be DeepSeek flash at $0.07/M in and $0.28/M out. +L4 latency averages ≈ 32 s per transcript.

**Post-run fix (orchestrator):** L1 now also redacts usernames that appear in a metadata or account context, e.g. author 'zlei', username: x, 用户名是x. The test is `test/gate-handle.test.mjs`. In a targeted real re-run (journalist, +L4, 2 samples; `results-journalist-handlefix.md`), outsider naming on journalist fell to 0/5 and direct, affil, quasi and style leaks were all 0. The single-transcript attack/retention numbers in that file (88.9 / 77.8, n=9 ideas) are noisy. The pooled tables above were NOT re-run, so the 4/50 outsider figure above predates this fix: 1 of those 4 is fixed, 1 is a scorer false positive, and 2 are topic inferences that do not appear in the digest text.
