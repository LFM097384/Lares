# Anonym Gate v2 — evaluation results

- Run: 2026-10-18T05:55:17.036Z
- Mode: MOCK — offline heuristics, NOT LLM numbers
- Configs: ideas-only, raw, L0+L1, +L2, +L3, +L4; threshold=0.5; flagThreshold=0.7; attack samples=1; mosaic=true
- Transcripts: academic (5 speakers, 8 ideas, 22 identifiers); bookclub (5 speakers, 9 ideas, 23 identifiers, 7 public facts, 5 tone markers, 1 self-authored works); faculty (5 speakers, 9 ideas, 21 identifiers, 7 public facts, 5 tone markers, 1 self-authored works); journalist (5 speakers, 9 ideas, 22 identifiers); medical (5 speakers, 8 ideas, 22 identifiers); ngo (5 speakers, 8 ideas, 22 identifiers); policy (5 speakers, 9 ideas, 22 identifiers, 7 public facts, 5 tone markers, 1 self-authored works); startup (5 speakers, 9 ideas, 22 identifiers); thinktank (5 speakers, 9 ideas, 22 identifiers); union (5 speakers, 8 ideas, 22 identifiers)
- Runtime / cost: wall 3s; gate tokens 0 (≈$0.0000); judge/attacker tokens 0 (≈$0.0000); assumed DeepSeek flash: $0.07/M in, $0.28/M out — prices are an **assumption**.
- Leak rates are pooled counts over transcripts. Random baseline = mean over ideas of 1/N speakers.
- **MOCK numbers**: gate L3/L4, attacker, tone and retention judges are deterministic heuristics, not an LLM. Do not quote as LLM results.

## Gate v2 metrics

New in Gate v2 (only the bookclub / policy / faculty transcripts carry this gold):
- **publicFactRetention** = public-world facts whose every `keep` string appears in the digest (normalised, case-insensitive, 《》/quotes stripped).
- **selfAuthorLeak** = participant-authored works (`gold.selfAuthor` work/fuzzy ∪ `roster[].works`) found in the digest; **publicNameLeak** = roster `publicName` found. Both must be 0.
- **toneLeak** = markers whose claim is present and the LLM judge still finds sarcasm / irony / backhanded praise / catchphrase / dialect / idiolect, OR any marker surface string appears verbatim (deterministic, OR'd) ÷ markers whose claim is present.
- **stancePreserved** = markers whose judged digest stance has the gold direction and |strength diff| ≤ 1 ÷ all markers (absent = not preserved).

| config | publicFactRetention% | selfAuthorLeak (works) | publicNameLeak | toneLeak% | stancePreserved% | directLeak% | affilLeak% | attackAcc% | retention% | flags public-fact / tone |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ideas-only | — | — | — | — | — | 0.0 | 0.0 | 24.4 | 0.0 | 0 / 0 of 0 |
| raw | 100.0 (21/21) | 3/3 | 1/1 | 100.0 (15/15) | 66.7 (10/15) | 100.0 | 100.0 | 37.2 | 77.9 | 0 / 0 of 251 |
| L0+L1 | 100.0 (21/21) | 3/3 | 0/1 | 100.0 (15/15) | 66.7 (10/15) | 4.8 | 100.0 | 24.4 | 75.6 | 0 / 0 of 648 |
| +L2 | 100.0 (21/21) | 0/3 | 0/1 | 100.0 (15/15) | 66.7 (10/15) | 2.4 | 0.0 | 24.4 | 74.4 | 0 / 0 of 648 |
| +L3 | 100.0 (21/21) | 0/3 | 0/1 | 60.0 (6/10) | 40.0 (6/15) | 2.4 | 0.0 | 24.4 | 49.4 | 0 / 21 of 645 |
| +L4 | 100.0 (21/21) | 0/3 | 0/1 | 60.0 (6/10) | 40.0 (6/15) | 2.4 | 0.0 | 24.4 | 49.4 | 0 / 21 of 645 |

## Targets (config +L4, pooled over the transcripts run)

| target | value | met |
| --- | --- | --- |
| publicFactRetention ≥ 90% | 100.0% | ✅ |
| toneLeak ≤ 10% | 60.0% | ❌ |
| stancePreserved ≥ 85% | 40.0% | ❌ |
| selfAuthorLeak = 0 (works + publicName) | 0 | ✅ |
| directLeak ≈ 0 (≤ 1%) | 2.4% | ❌ |
| affilLeak ≈ 0 (≤ 1%) | 0.0% | ✅ |
| outsider names 0 roster members | 6 | ❌ |
| idea retention ≥ 85% | 49.4% | ❌ |

## Aggregate (all metrics from the prototype)

| config | directLeak% | affilLeak% | quasiLeak% | styleLeak% | attackAcc% | randomBaseline% | retention% | avgLatencyMs | tokens | est$ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ideas-only | 0.0 | 0.0 | 0.0 | 0.0 | 24.4 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| raw | 100.0 | 100.0 | 100.0 | 100.0 | 37.2 | 20.0 | 77.9 | 62 | 0 | 0.00000 |
| L0+L1 | 4.8 | 100.0 | 96.4 | 100.0 | 24.4 | 20.0 | 75.6 | 69 | 0 | 0.00000 |
| +L2 | 2.4 | 0.0 | 71.4 | 100.0 | 24.4 | 20.0 | 74.4 | 73 | 0 | 0.00000 |
| +L3 | 2.4 | 0.0 | 42.9 | 47.6 | 24.4 | 20.0 | 49.4 | 128 | 0 | 0.00000 |
| +L4 | 2.4 | 0.0 | 42.9 | 47.6 | 24.4 | 20.0 | 49.4 | 133 | 0 | 0.00000 |

## Attacker knowledge levels

(a) full roster incl. org/title/works (insider-equivalent) = attackAcc% above; (b) names+aliases only; (c) outsider with no roster: how many roster members it can name (person or org, exact/fuzzy) and how many ideas it pins to the right person/org.

| config | (a) fullRoster attack% | (b) namesOnly attack% | (c) outsider: roster members named | (c) outsider: speaker hit% | random% |
| --- | --- | --- | --- | --- | --- |
| ideas-only | 24.4 | 16.3 | — | — | 20.0 |
| raw | 37.2 | 31.4 | 50/50 (50 by name, 21 by org) | 0.0 | 20.0 |
| +L3 | 24.4 | 16.3 | 6/50 (0 by name, 6 by org) | 0.0 | 20.0 |
| +L4 | 24.4 | 16.3 | 6/50 (0 by name, 6 by org) | 0.0 | 20.0 |

## Role-revealing risk flags (L4 residual)

"strict" = the digest with all flagged claims cut (full-roster attacker).

| transcript | flagged/claims | dropped | strict attack% | strict retention% |
| --- | --- | --- | --- | --- |
| academic | 0/65 | 0 | — | — |
| bookclub | 0/65 | 0 | — | — |
| faculty | 0/75 | 0 | — | — |
| journalist | 0/62 | 0 | — | — |
| medical | 0/49 | 0 | — | — |
| ngo | 0/64 | 0 | — | — |
| policy | 0/66 | 0 | — | — |
| startup | 0/73 | 0 | — | — |
| thinktank | 0/64 | 0 | — | — |
| union | 0/62 | 0 | — | — |
| ALL | 0/645 | 0 | — | — |

## Prototype → Gate v2 (same 7 old transcripts)

Prototype numbers from `server/chatham/eval/results.json` (2026-10-18T01:50:08.143Z, llm). Gate v2 numbers restricted to the same 7 transcripts. Format: prototype → v2.

| config | old transcripts | directLeak% proto→v2 | affilLeak% | quasiLeak% | styleLeak% | fullRoster attack% | namesOnly attack% | outsider named | retention% | gate est$ (total) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ideas-only | 7/7 | 0.0 → 0.0 | 0.0 → 0.0 | 0.0 → 0.0 | 0.0 → 0.0 | 62.7 → 22.0 | 47.5 → 13.6 | — | 0.0 → 0.0 | 0.0000 → 0.0000 |
| raw | 7/7 | 100.0 → 100.0 | 100.0 → 100.0 | 100.0 → 100.0 | 100.0 → 100.0 | 97.5 → 42.4 | 98.3 → 33.9 | 35/35 → 35/35 | 99.2 → 78.8 | 0.0000 → 0.0000 |
| L0+L1 | 7/7 | 1.1 → 2.2 | 100.0 → 100.0 | 100.0 → 100.0 | 100.0 → 100.0 | 72.0 → 23.7 | — | — | 91.5 → 75.4 | 0.0000 → 0.0000 |
| +L2 | 7/7 | 0.0 → 1.1 | 0.0 → 0.0 | 65.0 → 65.0 | 100.0 → 100.0 | 75.4 → 22.0 | — | — | 92.4 → 73.7 | 0.0000 → 0.0000 |
| +L3 | 7/7 | 0.0 → 1.1 | 0.0 → 0.0 | 5.0 → 25.0 | 3.7 → 37.0 | 72.0 → 22.0 | 45.8 → 13.6 | 0/35 → 1/35 | 87.3 → 50.0 | 0.0031 → 0.0000 |
| +L4 | 7/7 | 0.0 → 1.1 | 0.0 → 0.0 | 10.0 → 25.0 | 11.1 → 37.0 | 72.0 → 22.0 | 42.4 → 13.6 | 0/35 → 1/35 | 89.0 → 50.0 | 0.0181 → 0.0000 |

## Mosaic (cross-session linkage)

For each circle the transcript is split into 3 consecutive sessions (thirds of the lines; each gold idea assigned to the session whose raw text matches it best). The full Gate (+L4) runs per session. The full-roster attacker gets (a) each session digest alone, asked only about that session's ideas, and (b) all session digests concatenated, asked about all ideas. Mosaic gain = combined − alone. The knowledge store (core/memory.mjs) receives every session's claims as releases; recallForOutput is queried with the circle title and every gold idea (limit 5) and the union of returned items is attacked again.

| circle | sessions | ideas/claims per session | attack: each digest alone | attack: all digests combined | mosaic gain | outsider named: max alone → combined | memory recallForOutput |
| --- | --- | --- | --- | --- | --- | --- | --- |
| bookclub | 3 | 4i/20c, 3i/23c, 2i/22c | 33.3 (3/9) | 33.3 (3/9) | 0.0 pts | 0 → 0 | 0/50 dropped; 32/65 unique items out; attack 33.3 (3/9) |
| policy | 3 | 4i/21c, 2i/20c, 3i/25c | 44.4 (4/9) | 44.4 (4/9) | 0.0 pts | 0 → 0 | 0/49 dropped; 27/66 unique items out; attack 44.4 (4/9) |

## Gate v2 per transcript

| transcript | config | publicFactRetention | selfAuthor works + publicName | toneLeak | stancePreserved | flags public-fact / tone |
| --- | --- | --- | --- | --- | --- | --- |
| bookclub | raw | 100.0 (7/7) | 1/1 + 0/0 | 100.0 (5/5) | 40.0 (2/5) | 0 / 0 of 24 |
| bookclub | L0+L1 | 100.0 (7/7) | 1/1 + 0/0 | 100.0 (5/5) | 40.0 (2/5) | 0 / 0 of 66 |
| bookclub | +L2 | 100.0 (7/7) | 0/1 + 0/0 | 100.0 (5/5) | 40.0 (2/5) | 0 / 0 of 66 |
| bookclub | +L3 | 100.0 (7/7) | 0/1 + 0/0 | 100.0 (1/1) | 0.0 (0/5) | 0 / 12 of 65 |
| bookclub | +L4 | 100.0 (7/7) | 0/1 + 0/0 | 100.0 (1/1) | 0.0 (0/5) | 0 / 12 of 65 |
| faculty | raw | 100.0 (7/7) | 1/1 + 0/0 | 100.0 (5/5) | 100.0 (5/5) | 0 / 0 of 24 |
| faculty | L0+L1 | 100.0 (7/7) | 1/1 + 0/0 | 100.0 (5/5) | 100.0 (5/5) | 0 / 0 of 77 |
| faculty | +L2 | 100.0 (7/7) | 0/1 + 0/0 | 100.0 (5/5) | 100.0 (5/5) | 0 / 0 of 77 |
| faculty | +L3 | 100.0 (7/7) | 0/1 + 0/0 | 20.0 (1/5) | 100.0 (5/5) | 0 / 3 of 75 |
| faculty | +L4 | 100.0 (7/7) | 0/1 + 0/0 | 20.0 (1/5) | 100.0 (5/5) | 0 / 3 of 75 |
| policy | raw | 100.0 (7/7) | 1/1 + 1/1 | 100.0 (5/5) | 60.0 (3/5) | 0 / 0 of 23 |
| policy | L0+L1 | 100.0 (7/7) | 1/1 + 0/1 | 100.0 (5/5) | 60.0 (3/5) | 0 / 0 of 66 |
| policy | +L2 | 100.0 (7/7) | 0/1 + 0/1 | 100.0 (5/5) | 60.0 (3/5) | 0 / 0 of 66 |
| policy | +L3 | 100.0 (7/7) | 0/1 + 0/1 | 100.0 (4/4) | 20.0 (1/5) | 0 / 6 of 66 |
| policy | +L4 | 100.0 (7/7) | 0/1 + 0/1 | 100.0 (4/4) | 20.0 (1/5) | 0 / 6 of 66 |

### Gate v2 misses (+L3/+L4)

_Self-author and surface tone strings redacted to 2 chars; public-fact keep strings are public and shown._

| transcript | config | type | id | detail |
| --- | --- | --- | --- | --- |
| bookclub | +L3 | stance | t1 | present=false residual=false; judged absent/— vs gold oppose/3 |
| bookclub | +L3 | stance | t2 | present=false residual=false; judged absent/— vs gold oppose/2 |
| bookclub | +L3 | stance | t3 | present=false residual=false; judged absent/— vs gold oppose/3 |
| bookclub | +L3 | stance | t4 | present=false residual=false; judged absent/— vs gold oppose/2 |
| bookclub | +L3 | tone leak | t5 | present=true residual=false surface=这算…; judged absent/— vs gold doubt/2 |
| faculty | +L3 | tone leak | t3 | present=true residual=false surface=Wh…; judged oppose/3 vs gold oppose/3 |
| policy | +L3 | tone leak | t1 | present=true residual=false surface=讲得…,系车…; judged absent/— vs gold doubt/2 |
| policy | +L3 | tone leak | t2 | present=true residual=false surface=电网…,分分…; judged doubt/2 vs gold doubt/2 |
| policy | +L3 | tone leak | t3 | present=true residual=false surface=Oh…,真是…; judged absent/— vs gold oppose/3 |
| policy | +L3 | tone leak | t4 | present=true residual=false surface=演讲…,一量…; judged absent/— vs gold doubt/2 |
| policy | +L3 | stance | t5 | present=false residual=false; judged absent/— vs gold doubt/1 |
| bookclub | +L4 | stance | t1 | present=false residual=false; judged absent/— vs gold oppose/3 |
| bookclub | +L4 | stance | t2 | present=false residual=false; judged absent/— vs gold oppose/2 |
| bookclub | +L4 | stance | t3 | present=false residual=false; judged absent/— vs gold oppose/3 |
| bookclub | +L4 | stance | t4 | present=false residual=false; judged absent/— vs gold oppose/2 |
| bookclub | +L4 | tone leak | t5 | present=true residual=false surface=这算…; judged absent/— vs gold doubt/2 |
| faculty | +L4 | tone leak | t3 | present=true residual=false surface=Wh…; judged oppose/3 vs gold oppose/3 |
| policy | +L4 | tone leak | t1 | present=true residual=false surface=讲得…,系车…; judged absent/— vs gold doubt/2 |
| policy | +L4 | tone leak | t2 | present=true residual=false surface=电网…,分分…; judged doubt/2 vs gold doubt/2 |
| policy | +L4 | tone leak | t3 | present=true residual=false surface=Oh…,真是…; judged absent/— vs gold oppose/3 |
| policy | +L4 | tone leak | t4 | present=true residual=false surface=演讲…,一量…; judged absent/— vs gold doubt/2 |
| policy | +L4 | stance | t5 | present=false residual=false; judged absent/— vs gold doubt/1 |

## How to read this

- **ideas-only** is a floor: the attacker gets the roster and the bare gold idea texts, with no digest. No de-identification that keeps the idea can push the full-roster attack much below that floor.
- **(a) full roster with org/title** is an insider. **(c) outsider** is the outward threat: the digest must not reveal who attended.
- Gate v2 deliberately keeps public-world facts (named authors, laws, public bodies). The gold `org`/`title` identifiers in all 10 transcripts are participant-owned (owner p1..p5), so affilLeak keeps its meaning: any of them in the digest is a real leak.
- Attacker, gate and judges all use the same model family (deepseek-flash). n is small (10 synthetic transcripts; 15 tone markers, 21 public facts, 3 self-authored works): one marker ≈ 6.7 pts of toneLeak/stancePreserved. Judge noise matters.

## Per transcript

| transcript | config | directLeak% | affilLeak% | quasiLeak% | styleLeak% | attackAcc% | randomBaseline% | retention% | latencyMs | tokens | est$ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| academic | ideas-only | 0.0 (0/12) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/5) | 25.0 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| academic | raw | 100.0 (12/12) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (5/5) | 50.0 | 20.0 | 93.8 | 0 | 0 | 0.00000 |
| academic | L0+L1 | 8.3 (1/12) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (5/5) | 25.0 | 20.0 | 93.8 | 58 | 0 | 0.00000 |
| academic | +L2 | 8.3 (1/12) | 0.0 (0/2) | 100.0 (3/3) | 100.0 (5/5) | 25.0 | 20.0 | 93.8 | 69 | 0 | 0.00000 |
| academic | +L3 | 8.3 (1/12) | 0.0 (0/2) | 100.0 (3/3) | 40.0 (2/5) | 25.0 | 20.0 | 68.8 | 50 | 0 | 0.00000 |
| academic | +L4 | 8.3 (1/12) | 0.0 (0/2) | 100.0 (3/3) | 40.0 (2/5) | 25.0 | 20.0 | 68.8 | 58 | 0 | 0.00000 |
| bookclub | ideas-only | 0.0 (0/12) | 0.0 (0/3) | 0.0 (0/2) | 0.0 (0/6) | 33.3 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| bookclub | raw | 100.0 (12/12) | 100.0 (3/3) | 100.0 (2/2) | 100.0 (6/6) | 33.3 | 20.0 | 77.8 | 39 | 0 | 0.00000 |
| bookclub | L0+L1 | 8.3 (1/12) | 100.0 (3/3) | 100.0 (2/2) | 100.0 (6/6) | 33.3 | 20.0 | 77.8 | 74 | 0 | 0.00000 |
| bookclub | +L2 | 8.3 (1/12) | 0.0 (0/3) | 100.0 (2/2) | 100.0 (6/6) | 33.3 | 20.0 | 77.8 | 83 | 0 | 0.00000 |
| bookclub | +L3 | 8.3 (1/12) | 0.0 (0/3) | 100.0 (2/2) | 33.3 (2/6) | 33.3 | 20.0 | 44.4 | 107 | 0 | 0.00000 |
| bookclub | +L4 | 8.3 (1/12) | 0.0 (0/3) | 100.0 (2/2) | 33.3 (2/6) | 33.3 | 20.0 | 44.4 | 124 | 0 | 0.00000 |
| faculty | ideas-only | 0.0 (0/11) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/5) | 11.1 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| faculty | raw | 100.0 (11/11) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (5/5) | 11.1 | 20.0 | 100.0 | 83 | 0 | 0.00000 |
| faculty | L0+L1 | 9.1 (1/11) | 100.0 (2/2) | 66.7 (2/3) | 100.0 (5/5) | 11.1 | 20.0 | 100.0 | 91 | 0 | 0.00000 |
| faculty | +L2 | 0.0 (0/11) | 0.0 (0/2) | 66.7 (2/3) | 100.0 (5/5) | 11.1 | 20.0 | 100.0 | 97 | 0 | 0.00000 |
| faculty | +L3 | 0.0 (0/11) | 0.0 (0/2) | 66.7 (2/3) | 80.0 (4/5) | 11.1 | 20.0 | 72.2 | 173 | 0 | 0.00000 |
| faculty | +L4 | 0.0 (0/11) | 0.0 (0/2) | 66.7 (2/3) | 80.0 (4/5) | 11.1 | 20.0 | 72.2 | 178 | 0 | 0.00000 |
| journalist | ideas-only | 0.0 (0/13) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/4) | 22.2 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| journalist | raw | 100.0 (13/13) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (4/4) | 33.3 | 20.0 | 83.3 | 142 | 0 | 0.00000 |
| journalist | L0+L1 | 0.0 (0/13) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (4/4) | 22.2 | 20.0 | 83.3 | 129 | 0 | 0.00000 |
| journalist | +L2 | 0.0 (0/13) | 0.0 (0/2) | 66.7 (2/3) | 100.0 (4/4) | 22.2 | 20.0 | 83.3 | 128 | 0 | 0.00000 |
| journalist | +L3 | 0.0 (0/13) | 0.0 (0/2) | 0.0 (0/3) | 50.0 (2/4) | 22.2 | 20.0 | 61.1 | 266 | 0 | 0.00000 |
| journalist | +L4 | 0.0 (0/13) | 0.0 (0/2) | 0.0 (0/3) | 50.0 (2/4) | 22.2 | 20.0 | 61.1 | 270 | 0 | 0.00000 |
| medical | ideas-only | 0.0 (0/15) | 0.0 (0/2) | 0.0 (0/2) | 0.0 (0/3) | 37.5 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| medical | raw | 100.0 (15/15) | 100.0 (2/2) | 100.0 (2/2) | 100.0 (3/3) | 62.5 | 20.0 | 56.3 | 0 | 0 | 0.00000 |
| medical | L0+L1 | 0.0 (0/15) | 100.0 (2/2) | 100.0 (2/2) | 100.0 (3/3) | 37.5 | 20.0 | 56.3 | 37 | 0 | 0.00000 |
| medical | +L2 | 0.0 (0/15) | 0.0 (0/2) | 50.0 (1/2) | 100.0 (3/3) | 37.5 | 20.0 | 56.3 | 47 | 0 | 0.00000 |
| medical | +L3 | 0.0 (0/15) | 0.0 (0/2) | 0.0 (0/2) | 33.3 (1/3) | 37.5 | 20.0 | 31.3 | 48 | 0 | 0.00000 |
| medical | +L4 | 0.0 (0/15) | 0.0 (0/2) | 0.0 (0/2) | 33.3 (1/3) | 37.5 | 20.0 | 31.3 | 50 | 0 | 0.00000 |
| ngo | ideas-only | 0.0 (0/13) | 0.0 (0/3) | 0.0 (0/3) | 0.0 (0/3) | 25.0 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| ngo | raw | 100.0 (13/13) | 100.0 (3/3) | 100.0 (3/3) | 100.0 (3/3) | 37.5 | 20.0 | 87.5 | 42 | 0 | 0.00000 |
| ngo | L0+L1 | 0.0 (0/13) | 100.0 (3/3) | 100.0 (3/3) | 100.0 (3/3) | 25.0 | 20.0 | 87.5 | 54 | 0 | 0.00000 |
| ngo | +L2 | 0.0 (0/13) | 0.0 (0/3) | 66.7 (2/3) | 100.0 (3/3) | 25.0 | 20.0 | 81.3 | 53 | 0 | 0.00000 |
| ngo | +L3 | 0.0 (0/13) | 0.0 (0/3) | 66.7 (2/3) | 66.7 (2/3) | 25.0 | 20.0 | 56.3 | 100 | 0 | 0.00000 |
| ngo | +L4 | 0.0 (0/13) | 0.0 (0/3) | 66.7 (2/3) | 66.7 (2/3) | 25.0 | 20.0 | 56.3 | 96 | 0 | 0.00000 |
| policy | ideas-only | 0.0 (0/11) | 0.0 (0/4) | 0.0 (0/3) | 0.0 (0/4) | 44.4 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| policy | raw | 100.0 (11/11) | 100.0 (4/4) | 100.0 (3/3) | 100.0 (4/4) | 33.3 | 20.0 | 50.0 | 95 | 0 | 0.00000 |
| policy | L0+L1 | 18.2 (2/11) | 100.0 (4/4) | 100.0 (3/3) | 100.0 (4/4) | 33.3 | 20.0 | 50.0 | 83 | 0 | 0.00000 |
| policy | +L2 | 9.1 (1/11) | 0.0 (0/4) | 100.0 (3/3) | 100.0 (4/4) | 44.4 | 20.0 | 50.0 | 78 | 0 | 0.00000 |
| policy | +L3 | 9.1 (1/11) | 0.0 (0/4) | 100.0 (3/3) | 100.0 (4/4) | 44.4 | 20.0 | 27.8 | 164 | 0 | 0.00000 |
| policy | +L4 | 9.1 (1/11) | 0.0 (0/4) | 100.0 (3/3) | 100.0 (4/4) | 44.4 | 20.0 | 27.8 | 158 | 0 | 0.00000 |
| startup | ideas-only | 0.0 (0/12) | 0.0 (0/3) | 0.0 (0/2) | 0.0 (0/5) | 22.2 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| startup | raw | 100.0 (12/12) | 100.0 (3/3) | 100.0 (2/2) | 100.0 (5/5) | 33.3 | 20.0 | 88.9 | 165 | 0 | 0.00000 |
| startup | L0+L1 | 8.3 (1/12) | 100.0 (3/3) | 100.0 (2/2) | 100.0 (5/5) | 22.2 | 20.0 | 88.9 | 114 | 0 | 0.00000 |
| startup | +L2 | 0.0 (0/12) | 0.0 (0/3) | 100.0 (2/2) | 100.0 (5/5) | 22.2 | 20.0 | 83.3 | 102 | 0 | 0.00000 |
| startup | +L3 | 0.0 (0/12) | 0.0 (0/3) | 0.0 (0/2) | 20.0 (1/5) | 22.2 | 20.0 | 50.0 | 244 | 0 | 0.00000 |
| startup | +L4 | 0.0 (0/12) | 0.0 (0/3) | 0.0 (0/2) | 20.0 (1/5) | 22.2 | 20.0 | 50.0 | 233 | 0 | 0.00000 |
| thinktank | ideas-only | 0.0 (0/12) | 0.0 (0/2) | 0.0 (0/4) | 0.0 (0/4) | 11.1 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| thinktank | raw | 100.0 (12/12) | 100.0 (2/2) | 100.0 (4/4) | 100.0 (4/4) | 22.2 | 20.0 | 83.3 | 0 | 0 | 0.00000 |
| thinktank | L0+L1 | 0.0 (0/12) | 100.0 (2/2) | 100.0 (4/4) | 100.0 (4/4) | 11.1 | 20.0 | 61.1 | 14 | 0 | 0.00000 |
| thinktank | +L2 | 0.0 (0/12) | 0.0 (0/2) | 50.0 (2/4) | 100.0 (4/4) | 11.1 | 20.0 | 61.1 | 23 | 0 | 0.00000 |
| thinktank | +L3 | 0.0 (0/12) | 0.0 (0/2) | 0.0 (0/4) | 25.0 (1/4) | 11.1 | 20.0 | 50.0 | 22 | 0 | 0.00000 |
| thinktank | +L4 | 0.0 (0/12) | 0.0 (0/2) | 0.0 (0/4) | 25.0 (1/4) | 11.1 | 20.0 | 50.0 | 30 | 0 | 0.00000 |
| union | ideas-only | 0.0 (0/14) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/3) | 12.5 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| union | raw | 100.0 (14/14) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (3/3) | 62.5 | 20.0 | 56.3 | 54 | 0 | 0.00000 |
| union | L0+L1 | 0.0 (0/14) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (3/3) | 25.0 | 20.0 | 56.3 | 36 | 0 | 0.00000 |
| union | +L2 | 0.0 (0/14) | 0.0 (0/2) | 33.3 (1/3) | 100.0 (3/3) | 12.5 | 20.0 | 56.3 | 47 | 0 | 0.00000 |
| union | +L3 | 0.0 (0/14) | 0.0 (0/2) | 0.0 (0/3) | 33.3 (1/3) | 12.5 | 20.0 | 31.3 | 109 | 0 | 0.00000 |
| union | +L4 | 0.0 (0/14) | 0.0 (0/2) | 0.0 (0/3) | 33.3 (1/3) | 12.5 | 20.0 | 31.3 | 130 | 0 | 0.00000 |

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

### +L3 (35 leaked)

| transcript | category | kind | owner | identifier |
| --- | --- | --- | --- | --- |
| academic | direct | name | third | Pr… |
| academic | quasi | quasi | p4 | my… |
| academic | quasi | quasi | p5 | si… |
| academic | quasi | quasi | p1 | I'… |
| academic | style | style | p1 | To… |
| academic | style | style | p4 | Co… |
| bookclub | direct | name | third | 小罗… |
| bookclub | quasi | quasi | p4 | 我去… |
| bookclub | quasi | quasi | p3 | 我经… |
| bookclub | style | style | p2 | 讲句… |
| bookclub | style | style | p3 | 说到… |
| faculty | quasi | quasi | p4 | af… |
| faculty | quasi | quasi | p5 | 14… |
| faculty | style | style | p1 | Fo… |
| faculty | style | style | p2 | Wi… |
| faculty | style | style | p3 | Sp… |
| faculty | style | style | p4 | Qu… |
| journalist | style | style | p2 | Bo… |
| journalist | style | style | p4 | To… |
| medical | style | style | p3 | 从剂… |
| ngo | quasi | quasi | p4 | My… |
| ngo | quasi | quasi | p2 | 我上… |
| ngo | style | style | p1 | 说到… |
| ngo | style | style | p3 | 账面… |
| policy | direct | date | p1 | 我去… |
| policy | quasi | quasi | p5 | 我细… |
| policy | quasi | quasi | p4 | 我自… |
| policy | quasi | quasi | p1 | 我下… |
| policy | style | style | p2 | Fr… |
| policy | style | style | p3 | To… |
| policy | style | style | p4 | 从数… |
| policy | style | style | p5 | 老实… |
| startup | style | style | p4 | Ho… |
| thinktank | style | style | p5 | 从计… |
| union | style | style | p2 | 从法… |

### +L4 (35 leaked)

| transcript | category | kind | owner | identifier |
| --- | --- | --- | --- | --- |
| academic | direct | name | third | Pr… |
| academic | quasi | quasi | p4 | my… |
| academic | quasi | quasi | p5 | si… |
| academic | quasi | quasi | p1 | I'… |
| academic | style | style | p1 | To… |
| academic | style | style | p4 | Co… |
| bookclub | direct | name | third | 小罗… |
| bookclub | quasi | quasi | p4 | 我去… |
| bookclub | quasi | quasi | p3 | 我经… |
| bookclub | style | style | p2 | 讲句… |
| bookclub | style | style | p3 | 说到… |
| faculty | quasi | quasi | p4 | af… |
| faculty | quasi | quasi | p5 | 14… |
| faculty | style | style | p1 | Fo… |
| faculty | style | style | p2 | Wi… |
| faculty | style | style | p3 | Sp… |
| faculty | style | style | p4 | Qu… |
| journalist | style | style | p2 | Bo… |
| journalist | style | style | p4 | To… |
| medical | style | style | p3 | 从剂… |
| ngo | quasi | quasi | p4 | My… |
| ngo | quasi | quasi | p2 | 我上… |
| ngo | style | style | p1 | 说到… |
| ngo | style | style | p3 | 账面… |
| policy | direct | date | p1 | 我去… |
| policy | quasi | quasi | p5 | 我细… |
| policy | quasi | quasi | p4 | 我自… |
| policy | quasi | quasi | p1 | 我下… |
| policy | style | style | p2 | Fr… |
| policy | style | style | p3 | To… |
| policy | style | style | p4 | 从数… |
| policy | style | style | p5 | 老实… |
| startup | style | style | p4 | Ho… |
| thinktank | style | style | p5 | 从计… |
| union | style | style | p2 | 从法… |
