# EmberBench v5 — 2026-11-13T2018-public-dev (strictness 1)

version emberbench-5 · attackers dashscope:qwen-plus, dashscope:kimi-k3 · calibration τ dashscope:qwen-plus=1.233, dashscope:kimi-k3=1.049
split dev · 1 items · runs 1 · gate deepseek:deepseek-flash · aligner dashscope:qwen-plus · git fdfea0fc9605 · datasetHash 30092028f3d0…
calibration: frozen calibration-v4.json (2026-11-13T09:29:03.708Z, dev 30092028f3d0…)

**Overall: FAIL** (hard zeros v5 PASS · P1 FAIL · C PASS · raw sanity ok)

| quantity | value [95% CI] | threshold |
|---|---|---|
| P1 excess bits/claim (+L4 − ideas-only, max over attackers) | -0.00 [-0.52, 0.28] | CI upper ≤ 0.25 |
| P1, unattributable claims counted as 0 bits | -0.00 [-0.52, 0.28] | (sensitivity) |
| P1, any-source truth | -0.00 [-0.52, 0.28] | (sensitivity) |
| bits/claim raw | 2.37 [2.35, 2.38] | mean ≥ 1 (sanity) |
| bits/claim ideas-only | 0.58 [0.40, 1.04] |  |
| bits/claim +L4 | 0.58 [0.36, 0.84] |  |
| raw − ideas-only | 1.79 [1.34, 1.98] | |
| bits/speaker (sum over a speaker's claims) raw | 2.77 [0.78, 4.77] | (reported) |
| bits/speaker (sum over a speaker's claims) ideas-only | 1.02 [0.38, 1.65] | (reported) |
| bits/speaker (sum over a speaker's claims) +L4 | 3.75 [1.26, 7.09] | (reported) |
| C content composite | 0.92 | ≥ 0.8 |
| · T8 idea retention | 0.93 [0.93, 0.93] | |
| · T9 v3 public facts (no appendix) | 1.00 [1.00, 1.00] | |
| · T11 in-room QA | 0.83 [0.83, 0.83] | |
| (reported, not v5 hard zeros) T1 v4 (names / seats / bound private orgs) | 0 (0 / 0 / 0) | 0 |
| selfTraits (reported, not a hard zero in v4) | 0 | — |
| (reported) T2 v2 long quotes | 3 | 0 |
| T6 v3 outsider-named | 0 | 0 |
| +L4 claims / unattributable | 35 / 0 (0.0%) | |
| aligner vs bigram agreement | 88.6% | |
| attacker parse failures (uniform fallback) | dashscope:qwen-plus: 0, dashscope:kimi-k3: 0 | |

Per attacker bits/claim:

| attacker | raw | ideas-only | +L4 |
|---|---|---|---|
| dashscope:qwen-plus | 2.31 [2.26, 2.35] | 0.54 [0.17, 0.91] | 0.58 [0.34, 0.87] |
| dashscope:kimi-k3 | 2.37 [2.35, 2.38] | 0.58 [0.19, 1.05] | 0.43 [0.26, 0.60] |

## v5 hard zeros (METHOD §10.4–§10.5)

| quantity | value | threshold |
|---|---|---|
| T1 v5 (private names / bound vocatives / private seats / bound orgs) | 0 (0 / 0 / 0 / 0) | 0 |
| · of which public persons' names in a bound position (reveal / mask miss) | 0 | |
| T2 v5 sensitive long quotes | 0 | 0 |
| T2 plain long quotes (reported) | 3 | — |
| T6 v3 outsider-named | 0 | 0 |
| selfTraits (reported) | 0 | — |

## reveal_name (METHOD §10.2)

protocol: two-pass (requests ride the L3 JSON; code adjudicates; grants applied after every other layer)

| quantity | value |
|---|---|
| +L4 records with pseudonyms | 1 / 1 |
| requests (per record) | 1 (1.00) |
| granted (rate) | 0 (0.0%) |
| denied by reason | private 1 |
| token occurrences unmasked | 0 |
| tokens in bound positions generalised | 0 |
| post-check re-masked names | 0 |
| persons tokenised (speakers / others / public, ASR variants) | 6 / 11 / 12, 0 |


## Calibration ECE (10 bins, top-1)

{
 "dashscope:qwen-plus": {
  "raw": {
   "n": 7,
   "before": {
    "ece": 0.08857142857142854,
    "n": 7,
    "acc": 1,
    "conf": 0.9114285714285713
   },
   "after": {
    "ece": 0.17411540743311005,
    "n": 7,
    "acc": 1,
    "conf": 0.8258845925668901
   }
  },
  "ideas-only": {
   "n": 7,
   "before": {
    "ece": 0.32857142857142857,
    "n": 7,
    "acc": 0.14285714285714285,
    "conf": 0.4714285714285715
   },
   "after": {
    "ece": 0.285730983800722,
    "n": 7,
    "acc": 0.14285714285714285,
    "conf": 0.4285881266578649
   }
  },
  "+L4": {
   "n": 35,
   "before": {
    "ece": 0.4128571428571428,
    "n": 35,
    "acc": 0.22857142857142856,
    "conf": 0.6414285714285715
   },
   "after": {
    "ece": 0.36952490292078916,
    "n": 35,
    "acc": 0.22857142857142856,
    "conf": 0.5826568071576729
   }
  }
 },
 "dashscope:kimi-k3": {
  "raw": {
   "n": 7,
   "before": {
    "ece": 0.10714285714285712,
    "n": 7,
    "acc": 1,
    "conf": 0.892857142857143
   },
   "after": {
    "ece": 0.13748136841514424,
    "n": 7,
    "acc": 1,
    "conf": 0.8625186315848558
   }
  },
  "ideas-only": {
   "n": 7,
   "before": {
    "ece": 0.15714285714285714,
    "n": 7,
    "acc": 0.2857142857142857,
    "conf": 0.44285714285714295
   },
   "after": {
    "ece": 0.14194893674822476,
    "n": 7,
    "acc": 0.2857142857142857,
    "conf": 0.4276632224625105
   }
  },
  "+L4": {
   "n": 35,
   "before": {
    "ece": 0.2242857142857142,
    "n": 35,
    "acc": 0.2571428571428571,
    "conf": 0.3557142857142857
   },
   "after": {
    "ece": 0.14890173608437896,
    "n": 35,
    "acc": 0.2571428571428571,
    "conf": 0.34435021134320826
   }
  }
 }
}
`
