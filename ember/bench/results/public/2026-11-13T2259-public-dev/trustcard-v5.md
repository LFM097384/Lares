# EmberBench v5 — 2026-11-13T2259-public-dev (strictness 1)

version emberbench-5 · attackers dashscope:qwen-plus, dashscope:kimi-k3 · calibration τ dashscope:qwen-plus=1.233, dashscope:kimi-k3=1.049
split dev · 18 items · runs 3 · gate deepseek:deepseek-flash · aligner dashscope:qwen-plus · git 9ee84c8bd93d (dirty) · datasetHash 30092028f3d0…
calibration: frozen calibration-v4.json (2026-11-13T09:29:03.708Z, dev 30092028f3d0…)

**Overall: PASS** (hard zeros v5 PASS · P1 PASS · C PASS · raw sanity ok)

| quantity | value [95% CI] | threshold |
|---|---|---|
| P1 excess bits/claim (+L4 − ideas-only, max over attackers) | 0.01 [-0.20, 0.18] | CI upper ≤ 0.25 |
| P1, unattributable claims counted as 0 bits | -0.01 [-0.21, 0.15] | (sensitivity) |
| P1, any-source truth | 0.05 [-0.16, 0.23] | (sensitivity) |
| bits/claim raw | 2.32 [2.07, 2.59] | mean ≥ 1 (sanity) |
| bits/claim ideas-only | 1.04 [0.75, 1.39] |  |
| bits/claim +L4 | 1.05 [0.81, 1.29] |  |
| raw − ideas-only | 1.27 [0.99, 1.55] | |
| bits/speaker (sum over a speaker's claims) raw | 2.08 [1.53, 2.68] | (reported) |
| bits/speaker (sum over a speaker's claims) ideas-only | 1.04 [0.71, 1.43] | (reported) |
| bits/speaker (sum over a speaker's claims) +L4 | 5.99 [4.22, 7.99] | (reported) |
| C content composite | 0.82 | ≥ 0.8 |
| · T8 idea retention | 0.86 [0.82, 0.91] | |
| · T9 v3 public facts (no appendix) | 0.82 [0.72, 0.89] | |
| · T11 in-room QA | 0.78 [0.66, 0.90] | |
| (reported, not v5 hard zeros) T1 v4 (names / seats / bound private orgs) | 0 (0 / 0 / 0) | 0 |
| selfTraits (reported, not a hard zero in v4) | 0 | — |
| (reported) T2 v2 long quotes | 101 | 0 |
| T6 v3 outsider-named | 0 | 0 |
| +L4 claims / unattributable | 2107 / 34 (1.6%) | |
| aligner vs bigram agreement | 87.5% | |
| attacker parse failures (uniform fallback) | dashscope:qwen-plus: 1, dashscope:kimi-k3: 0 | |

Per attacker bits/claim:

| attacker | raw | ideas-only | +L4 |
|---|---|---|---|
| dashscope:qwen-plus | 2.20 [1.92, 2.50] | 0.97 [0.69, 1.24] | 0.98 [0.77, 1.19] |
| dashscope:kimi-k3 | 2.30 [2.02, 2.61] | 0.96 [0.64, 1.28] | 0.96 [0.70, 1.23] |

Memorisation probe (18 items): bits/excerpt 1.61 [1.37, 1.90], excess over ideas-only 0.57 [0.23, 0.91], meeting (year+month) hit rate 6% (dashscope:qwen-plus 1, dashscope:kimi-k3 1) → no memorisation flag

## v5 hard zeros (METHOD §10.4–§10.5)

| quantity | value | threshold |
|---|---|---|
| T1 v5 (private names / bound vocatives / private seats / bound orgs) | 0 (0 / 0 / 0 / 0) | 0 |
| · of which public persons' names in a bound position (reveal / mask miss) | 0 | |
| T2 v5 sensitive long quotes | 0 | 0 |
| T2 plain long quotes (reported) | 101 | — |
| T6 v3 outsider-named | 0 | 0 |
| selfTraits (reported) | 0 | — |

## reveal_name (METHOD §10.2)

protocol: two-pass (requests ride the L3 JSON; code adjudicates; grants applied after every other layer)

| quantity | value |
|---|---|
| +L4 records with pseudonyms | 54 / 54 |
| requests (per record) | 9 (0.17) |
| granted (rate) | 0 (0.0%) |
| denied by reason | private 9 |
| token occurrences unmasked | 0 |
| tokens in bound positions generalised | 15 |
| post-check re-masked names | 0 |
| persons tokenised (speakers / others / public, ASR variants) | 411 / 405 / 567, 0 |


## Calibration ECE (10 bins, top-1)

{
 "dashscope:qwen-plus": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.061747267759561644,
    "n": 366,
    "acc": 0.8633879781420765,
    "conf": 0.9151898907103824
   },
   "after": {
    "ece": 0.03914714245911763,
    "n": 366,
    "acc": 0.8633879781420765,
    "conf": 0.8427173635223781
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.24786994535519125,
    "n": 366,
    "acc": 0.3879781420765027,
    "conf": 0.6358480874316932
   },
   "after": {
    "ece": 0.19020603266046232,
    "n": 366,
    "acc": 0.3879781420765027,
    "conf": 0.5740751363291158
   }
  },
  "+L4": {
   "n": 2073,
   "before": {
    "ece": 0.22920487216594249,
    "n": 2073,
    "acc": 0.40665701881331406,
    "conf": 0.6358618909792586
   },
   "after": {
    "ece": 0.16899251112861965,
    "n": 2073,
    "acc": 0.40665701881331406,
    "conf": 0.5750559204487218
   }
  }
 },
 "dashscope:kimi-k3": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.030637431693988075,
    "n": 366,
    "acc": 0.8770491803278688,
    "conf": 0.8965756830601079
   },
   "after": {
    "ece": 0.047495992310069166,
    "n": 366,
    "acc": 0.8770491803278688,
    "conf": 0.8697743378779235
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.0703464480874317,
    "n": 366,
    "acc": 0.43989071038251365,
    "conf": 0.48602950819672114
   },
   "after": {
    "ece": 0.08200634923387398,
    "n": 366,
    "acc": 0.43989071038251365,
    "conf": 0.46766689967679576
   }
  },
  "+L4": {
   "n": 2073,
   "before": {
    "ece": 0.02615914134105221,
    "n": 2073,
    "acc": 0.482392667631452,
    "conf": 0.4804327544621323
   },
   "after": {
    "ece": 0.03150917210936281,
    "n": 2073,
    "acc": 0.482392667631452,
    "conf": 0.4624322352887028
   }
  }
 }
}
`
