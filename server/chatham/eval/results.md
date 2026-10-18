# Chatham Gate — evaluation results

- Run: 2026-10-18T01:50:08.143Z
- Mode: LLM (judge model: deepseek-flash)
- Gate run with mock=false; threshold=0.5; flagThreshold=0.7; attack samples=2
- Transcripts: academic (5 speakers, 8 ideas, 22 identifiers); journalist (5 speakers, 9 ideas, 22 identifiers); medical (5 speakers, 8 ideas, 22 identifiers); ngo (5 speakers, 8 ideas, 22 identifiers); startup (5 speakers, 9 ideas, 22 identifiers); thinktank (5 speakers, 9 ideas, 22 identifiers); union (5 speakers, 8 ideas, 22 identifiers)
- Cost estimate: assumed DeepSeek flash: $0.07/M in, $0.28/M out — **assumption**. Latency and tokens are gate-only (judge/attacker calls excluded).
- Leak rates are pooled counts over transcripts. Random baseline = mean over ideas of 1/N speakers.

## Aggregate

| config | directLeak% | affilLeak% | quasiLeak% | styleLeak% | attackAcc% | randomBaseline% | retention% | avgLatencyMs | tokens | est$ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ideas-only | 0.0 | 0.0 | 0.0 | 0.0 | 62.7 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| raw | 100.0 | 100.0 | 100.0 | 100.0 | 97.5 | 20.0 | 99.2 | 2 | 0 | 0.00000 |
| L0+L1 | 1.1 | 100.0 | 100.0 | 100.0 | 72.0 | 20.0 | 91.5 | 20 | 0 | 0.00000 |
| +L2 | 0.0 | 0.0 | 65.0 | 100.0 | 75.4 | 20.0 | 92.4 | 27 | 0 | 0.00000 |
| +L3 | 0.0 | 0.0 | 5.0 | 3.7 | 72.0 | 20.0 | 87.3 | 6379 | 21043 | 0.00312 |
| +L4 | 0.0 | 0.0 | 10.0 | 11.1 | 72.0 | 20.0 | 89.0 | 29896 | 110633 | 0.01811 |

## Attacker knowledge levels

(a) full roster incl. org/title (insider-equivalent) = attackAcc% above; (b) names+aliases only; (c) outsider with no roster: how many roster members it can name (person or org, exact/fuzzy) and how many ideas it pins to the right person/org.

| config | (a) fullRoster attack% | (b) namesOnly attack% | (c) outsider: roster members named | (c) outsider: speaker hit% | random% |
| --- | --- | --- | --- | --- | --- |
| ideas-only | 62.7 | 47.5 | — | — | 20.0 |
| raw | 97.5 | 98.3 | 35/35 (35 by name, 17 by org) | 98.3 | 20.0 |
| +L3 | 72.0 | 45.8 | 0/35 (0 by name, 0 by org) | 0.0 | 20.0 |
| +L4 | 72.0 | 42.4 | 0/35 (0 by name, 0 by org) | 0.0 | 20.0 |

## Role-revealing risk flags (L4 residual)

Claims still attributable at ≥ threshold after the last L4 round are marked `[review: role-revealing]` for human review instead of being silently kept or dropped. "strict" = the digest with all flagged claims cut (full-roster attacker).

| transcript | flagged/claims | dropped | strict attack% | strict retention% |
| --- | --- | --- | --- | --- |
| academic | 0/54 | 1 | — | — |
| journalist | 0/50 | 0 | — | — |
| medical | 5/45 | 0 | 100.0 | 87.5 |
| ngo | 0/52 | 0 | — | — |
| startup | 9/56 | 0 | 66.7 | 72.2 |
| thinktank | 2/55 | 0 | 22.2 | 100.0 |
| union | 16/48 | 0 | 75.0 | 50.0 |
| ALL | 32/360 | 1 | 64.7 | 77.4 |

## How to read this

- **ideas-only** is a floor: the attacker gets the roster and the bare gold idea texts, with no digest. Its accuracy is the attribution that is inherent in *what* was said (e.g. "only the oncologist would argue for surgery"). No de-identification that keeps the idea can push the full-roster attack much below that floor.
- **(a) full roster with org/title** is an insider: someone in the room, or who knows the attendee list and their jobs. The Gate removes the surface signals (names, orgs, style) and brings accuracy from ~raw down to about the ideas-only floor, but not to random 1/N. That gap is the honest core finding: role-linked content stays attributable to insiders.
- **(c) outsider with no roster** is the outward threat the Rule targets: the digest must not reveal who attended. This is the number to watch for public release.
- Role-revealing flags (`--flag-threshold`, default 0.7) are a review aid, not a guarantee. The full digest is what an insider sees if reviewers keep everything; "strict" is the digest if reviewers cut every flagged claim.
- Attacker, generaliser and judge all use the same model (deepseek-flash). A stronger or differently-trained attacker may do better. n = 7 synthetic transcripts × 8–9 ideas, 2 attack samples: differences of a few points are noise.

## Per transcript

| transcript | config | directLeak% | affilLeak% | quasiLeak% | styleLeak% | attackAcc% | randomBaseline% | retention% | latencyMs | tokens | est$ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| academic | ideas-only | 0.0 (0/12) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/5) | 43.8 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| academic | raw | 100.0 (12/12) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (5/5) | 100.0 | 20.0 | 100.0 | 1 | 0 | 0.00000 |
| academic | L0+L1 | 0.0 (0/12) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (5/5) | 50.0 | 20.0 | 100.0 | 43 | 0 | 0.00000 |
| academic | +L2 | 0.0 (0/12) | 0.0 (0/2) | 100.0 (3/3) | 100.0 (5/5) | 62.5 | 20.0 | 100.0 | 55 | 0 | 0.00000 |
| academic | +L3 | 0.0 (0/12) | 0.0 (0/2) | 33.3 (1/3) | 0.0 (0/5) | 56.3 | 20.0 | 93.8 | 5385 | 2870 | 0.00042 |
| academic | +L4 | 0.0 (0/12) | 0.0 (0/2) | 66.7 (2/3) | 0.0 (0/5) | 56.3 | 20.0 | 93.8 | 27269 | 14802 | 0.00248 |
| journalist | ideas-only | 0.0 (0/13) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/4) | 72.2 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| journalist | raw | 100.0 (13/13) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (4/4) | 100.0 | 20.0 | 100.0 | 4 | 0 | 0.00000 |
| journalist | L0+L1 | 0.0 (0/13) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (4/4) | 88.9 | 20.0 | 83.3 | 29 | 0 | 0.00000 |
| journalist | +L2 | 0.0 (0/13) | 0.0 (0/2) | 66.7 (2/3) | 100.0 (4/4) | 77.8 | 20.0 | 88.9 | 40 | 0 | 0.00000 |
| journalist | +L3 | 0.0 (0/13) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/4) | 77.8 | 20.0 | 77.8 | 6550 | 2786 | 0.00042 |
| journalist | +L4 | 0.0 (0/13) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/4) | 83.3 | 20.0 | 83.3 | 29841 | 15379 | 0.00255 |
| medical | ideas-only | 0.0 (0/15) | 0.0 (0/2) | 0.0 (0/2) | 0.0 (0/3) | 93.8 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| medical | raw | 100.0 (15/15) | 100.0 (2/2) | 100.0 (2/2) | 100.0 (3/3) | 100.0 | 20.0 | 100.0 | 6 | 0 | 0.00000 |
| medical | L0+L1 | 0.0 (0/15) | 100.0 (2/2) | 100.0 (2/2) | 100.0 (3/3) | 87.5 | 20.0 | 100.0 | 21 | 0 | 0.00000 |
| medical | +L2 | 0.0 (0/15) | 0.0 (0/2) | 50.0 (1/2) | 100.0 (3/3) | 93.8 | 20.0 | 100.0 | 32 | 0 | 0.00000 |
| medical | +L3 | 0.0 (0/15) | 0.0 (0/2) | 0.0 (0/2) | 33.3 (1/3) | 100.0 | 20.0 | 100.0 | 5769 | 2948 | 0.00042 |
| medical | +L4 | 0.0 (0/15) | 0.0 (0/2) | 0.0 (0/2) | 33.3 (1/3) | 87.5 | 20.0 | 100.0 | 31554 | 16930 | 0.00272 |
| ngo | ideas-only | 0.0 (0/13) | 0.0 (0/3) | 0.0 (0/3) | 0.0 (0/3) | 75.0 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| ngo | raw | 100.0 (13/13) | 100.0 (3/3) | 100.0 (3/3) | 100.0 (3/3) | 100.0 | 20.0 | 100.0 | 6 | 0 | 0.00000 |
| ngo | L0+L1 | 0.0 (0/13) | 100.0 (3/3) | 100.0 (3/3) | 100.0 (3/3) | 75.0 | 20.0 | 87.5 | 14 | 0 | 0.00000 |
| ngo | +L2 | 0.0 (0/13) | 0.0 (0/3) | 66.7 (2/3) | 100.0 (3/3) | 75.0 | 20.0 | 87.5 | 23 | 0 | 0.00000 |
| ngo | +L3 | 0.0 (0/13) | 0.0 (0/3) | 0.0 (0/3) | 0.0 (0/3) | 81.3 | 20.0 | 87.5 | 7574 | 3122 | 0.00047 |
| ngo | +L4 | 0.0 (0/13) | 0.0 (0/3) | 0.0 (0/3) | 0.0 (0/3) | 87.5 | 20.0 | 93.8 | 27356 | 12588 | 0.00205 |
| startup | ideas-only | 0.0 (0/12) | 0.0 (0/3) | 0.0 (0/2) | 0.0 (0/5) | 66.7 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| startup | raw | 100.0 (12/12) | 100.0 (3/3) | 100.0 (2/2) | 100.0 (5/5) | 94.4 | 20.0 | 100.0 | 0 | 0 | 0.00000 |
| startup | L0+L1 | 8.3 (1/12) | 100.0 (3/3) | 100.0 (2/2) | 100.0 (5/5) | 83.3 | 20.0 | 88.9 | 18 | 0 | 0.00000 |
| startup | +L2 | 0.0 (0/12) | 0.0 (0/3) | 100.0 (2/2) | 100.0 (5/5) | 77.8 | 20.0 | 94.4 | 12 | 0 | 0.00000 |
| startup | +L3 | 0.0 (0/12) | 0.0 (0/3) | 0.0 (0/2) | 0.0 (0/5) | 77.8 | 20.0 | 88.9 | 6325 | 3140 | 0.00046 |
| startup | +L4 | 0.0 (0/12) | 0.0 (0/3) | 0.0 (0/2) | 20.0 (1/5) | 77.8 | 20.0 | 83.3 | 30908 | 17315 | 0.00282 |
| thinktank | ideas-only | 0.0 (0/12) | 0.0 (0/2) | 0.0 (0/4) | 0.0 (0/4) | 27.8 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| thinktank | raw | 100.0 (12/12) | 100.0 (2/2) | 100.0 (4/4) | 100.0 (4/4) | 88.9 | 20.0 | 94.4 | 0 | 0 | 0.00000 |
| thinktank | L0+L1 | 0.0 (0/12) | 100.0 (2/2) | 100.0 (4/4) | 100.0 (4/4) | 50.0 | 20.0 | 94.4 | 10 | 0 | 0.00000 |
| thinktank | +L2 | 0.0 (0/12) | 0.0 (0/2) | 50.0 (2/4) | 100.0 (4/4) | 61.1 | 20.0 | 94.4 | 11 | 0 | 0.00000 |
| thinktank | +L3 | 0.0 (0/12) | 0.0 (0/2) | 0.0 (0/4) | 0.0 (0/4) | 33.3 | 20.0 | 88.9 | 6762 | 3219 | 0.00049 |
| thinktank | +L4 | 0.0 (0/12) | 0.0 (0/2) | 0.0 (0/4) | 25.0 (1/4) | 38.9 | 20.0 | 94.4 | 32331 | 17460 | 0.00290 |
| union | ideas-only | 0.0 (0/14) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/3) | 62.5 | 20.0 | 0.0 | 0 | 0 | 0.00000 |
| union | raw | 100.0 (14/14) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (3/3) | 100.0 | 20.0 | 100.0 | 0 | 0 | 0.00000 |
| union | L0+L1 | 0.0 (0/14) | 100.0 (2/2) | 100.0 (3/3) | 100.0 (3/3) | 68.8 | 20.0 | 87.5 | 7 | 0 | 0.00000 |
| union | +L2 | 0.0 (0/14) | 0.0 (0/2) | 33.3 (1/3) | 100.0 (3/3) | 81.3 | 20.0 | 81.3 | 13 | 0 | 0.00000 |
| union | +L3 | 0.0 (0/14) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/3) | 81.3 | 20.0 | 75.0 | 6285 | 2958 | 0.00044 |
| union | +L4 | 0.0 (0/14) | 0.0 (0/2) | 0.0 (0/3) | 0.0 (0/3) | 75.0 | 20.0 | 75.0 | 30013 | 16159 | 0.00261 |

## Leaked identifiers per config

_Leaked strings are redacted to their first 2 characters._

### ideas-only (0 leaked)

_none_

### raw (154 leaked)

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

### L0+L1 (64 leaked)

| transcript | category | kind | owner | identifier |
| --- | --- | --- | --- | --- |
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

### +L2 (40 leaked)

| transcript | category | kind | owner | identifier |
| --- | --- | --- | --- | --- |
| academic | quasi | quasi | p4 | my… |
| academic | quasi | quasi | p5 | si… |
| academic | quasi | quasi | p1 | I'… |
| academic | style | style | p1 | To… |
| academic | style | style | p2 | Le… |
| academic | style | style | p3 | If… |
| academic | style | style | p5 | To… |
| academic | style | style | p4 | Co… |
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

### +L3 (2 leaked)

| transcript | category | kind | owner | identifier |
| --- | --- | --- | --- | --- |
| academic | quasi | quasi | p1 | I'… |
| medical | style | style | p3 | 从剂… |

### +L4 (5 leaked)

| transcript | category | kind | owner | identifier |
| --- | --- | --- | --- | --- |
| academic | quasi | quasi | p4 | my… |
| academic | quasi | quasi | p1 | I'… |
| medical | style | style | p3 | 从剂… |
| startup | style | style | p3 | 本质… |
| thinktank | style | style | p5 | 从计… |
