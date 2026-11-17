# EmberBench v4 — 2026-11-13T1042-public-test (strictness 1)

version emberbench-4 · attackers dashscope:qwen-plus, dashscope:kimi-k3 · calibration τ dashscope:qwen-plus=1.233, dashscope:kimi-k3=1.049
split test · 60 items · runs 3 · gate deepseek:deepseek-flash · aligner dashscope:qwen-plus · git 557436160951 · datasetHash 4ae36afd66ff…
calibration: frozen calibration-v4.json (2026-11-13T09:29:03.708Z, dev 30092028f3d0…)

**Overall: FAIL** (hard zeros FAIL · P1 PASS · C PASS · raw sanity ok)

| quantity | value [95% CI] | threshold |
|---|---|---|
| P1 excess bits/claim (+L4 − ideas-only, max over attackers) | -0.07 [-0.17, 0.01] | CI upper ≤ 0.25 |
| P1, unattributable claims counted as 0 bits | -0.08 [-0.18, -0.01] | (sensitivity) |
| P1, any-source truth | -0.01 [-0.11, 0.07] | (sensitivity) |
| bits/claim raw | 2.35 [2.27, 2.44] | mean ≥ 1 (sanity) |
| bits/claim ideas-only | 0.93 [0.82, 1.05] |  |
| bits/claim +L4 | 0.86 [0.79, 0.95] |  |
| raw − ideas-only | 1.42 [1.28, 1.55] | |
| bits/speaker (sum over a speaker's claims) raw | 2.67 [2.34, 3.03] | (reported) |
| bits/speaker (sum over a speaker's claims) ideas-only | 1.14 [0.94, 1.34] | (reported) |
| bits/speaker (sum over a speaker's claims) +L4 | 5.54 [4.72, 6.44] | (reported) |
| C content composite | 0.80 | ≥ 0.8 |
| · T8 idea retention | 0.83 [0.80, 0.86] | |
| · T9 v3 public facts (no appendix) | 0.66 [0.61, 0.71] | |
| · T11 in-room QA | 0.92 [0.87, 0.95] | |
| T1 v4 (names / seats / bound private orgs) | 47 (11 / 29 / 7) | 0 |
| selfTraits (reported, not a hard zero in v4) | 20 | — |
| T2 long quotes | 2 | 0 |
| T6 v3 outsider-named | 3 | 0 |
| +L4 claims / unattributable | 6568 / 104 (1.6%) | |
| aligner vs bigram agreement | 83.5% | |
| attacker parse failures (uniform fallback) | dashscope:qwen-plus: 1, dashscope:kimi-k3: 0 | |

Per attacker bits/claim:

| attacker | raw | ideas-only | +L4 |
|---|---|---|---|
| dashscope:qwen-plus | 2.25 [2.13, 2.35] | 0.86 [0.75, 0.97] | 0.83 [0.75, 0.91] |
| dashscope:kimi-k3 | 2.30 [2.20, 2.39] | 0.76 [0.64, 0.87] | 0.75 [0.66, 0.84] |

## Calibration ECE (10 bins, top-1)

{
 "dashscope:qwen-plus": {
  "raw": {
   "n": 1230,
   "before": {
    "ece": 0.02606504065039852,
    "n": 1230,
    "acc": 0.9504065040650407,
    "conf": 0.9243414634146453
   },
   "after": {
    "ece": 0.09688272370872109,
    "n": 1230,
    "acc": 0.9504065040650407,
    "conf": 0.8539633913481073
   }
  },
  "ideas-only": {
   "n": 1230,
   "before": {
    "ece": 0.22214300813008186,
    "n": 1230,
    "acc": 0.39186991869918697,
    "conf": 0.6123869105691055
   },
   "after": {
    "ece": 0.16443814967522072,
    "n": 1230,
    "acc": 0.39186991869918697,
    "conf": 0.5526465858943472
   }
  },
  "+L4": {
   "n": 6464,
   "before": {
    "ece": 0.24186772896039574,
    "n": 6464,
    "acc": 0.3717512376237624,
    "conf": 0.6133611386138523
   },
   "after": {
    "ece": 0.18463882494125797,
    "n": 6464,
    "acc": 0.3717512376237624,
    "conf": 0.5563900625650222
   }
  }
 },
 "dashscope:kimi-k3": {
  "raw": {
   "n": 1230,
   "before": {
    "ece": 0.07714178861788519,
    "n": 1230,
    "acc": 0.9617886178861789,
    "conf": 0.8877362601626091
   },
   "after": {
    "ece": 0.10093703395275162,
    "n": 1230,
    "acc": 0.9617886178861789,
    "conf": 0.861366543037332
   }
  },
  "ideas-only": {
   "n": 1230,
   "before": {
    "ece": 0.07584439024390296,
    "n": 1230,
    "acc": 0.4170731707317073,
    "conf": 0.45057837398374007
   },
   "after": {
    "ece": 0.06711085895518683,
    "n": 1230,
    "acc": 0.4170731707317073,
    "conf": 0.43478157250743327
   }
  },
  "+L4": {
   "n": 6464,
   "before": {
    "ece": 0.047716615099009374,
    "n": 6464,
    "acc": 0.4238861386138614,
    "conf": 0.4489722153465404
   },
   "after": {
    "ece": 0.04278393398575078,
    "n": 6464,
    "acc": 0.4238861386138614,
    "conf": 0.43316548877878314
   }
  }
 }
}
`
