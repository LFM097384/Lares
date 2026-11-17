# EmberBench v5 — 2026-11-15T2050-public-dev (strictness 1)

version emberbench-5 · attackers dashscope:qwen-plus, dashscope:kimi-k3 · calibration τ dashscope:qwen-plus=1.233, dashscope:kimi-k3=1.049
split dev · 18 items · runs 3 · gate chatgpt:gpt-5.6-terra · aligner dashscope:qwen-plus · git 1541d3950588 (dirty) · datasetHash 30092028f3d0…
calibration: frozen calibration-v4.json (2026-11-13T09:29:03.708Z, dev 30092028f3d0…)

**Overall: FAIL** (hard zeros v5 PASS · P1 PASS · C FAIL · raw sanity ok)

| quantity | value [95% CI] | threshold |
|---|---|---|
| P1 excess bits/claim (+L4 − ideas-only, max over attackers) | -0.02 [-0.24, 0.16] | CI upper ≤ 0.25 |
| P1, unattributable claims counted as 0 bits | -0.03 [-0.24, 0.16] | (sensitivity) |
| P1, any-source truth | 0.05 [-0.19, 0.25] | (sensitivity) |
| bits/claim raw | 2.34 [2.10, 2.61] | mean ≥ 1 (sanity) |
| bits/claim ideas-only | 1.04 [0.81, 1.35] |  |
| bits/claim +L4 | 1.02 [0.83, 1.24] |  |
| raw − ideas-only | 1.30 [1.03, 1.52] | |
| bits/speaker (sum over a speaker's claims) raw | 2.11 [1.56, 2.72] | (reported) |
| bits/speaker (sum over a speaker's claims) ideas-only | 1.02 [0.70, 1.40] | (reported) |
| bits/speaker (sum over a speaker's claims) +L4 | 2.77 [1.85, 3.87] | (reported) |
| C content composite | 0.62 | ≥ 0.8 |
| · T8 idea retention | 0.49 [0.42, 0.57] | |
| · T9 v3 public facts (no appendix) | 0.51 [0.38, 0.63] | |
| · T11 in-room QA | 0.88 [0.77, 0.96] | |
| (reported, not v5 hard zeros) T1 v4 (names / seats / bound private orgs) | 0 (0 / 0 / 0) | 0 |
| selfTraits (reported, not a hard zero in v4) | 0 | — |
| (reported) T2 v2 long quotes | 28 | 0 |
| T6 v3 outsider-named | 0 | 0 |
| +L4 claims / unattributable | 1044 / 11 (1.1%) | |
| aligner vs bigram agreement | 85.1% | |
| attacker parse failures (uniform fallback) | dashscope:qwen-plus: 1, dashscope:kimi-k3: 0 | |

Per attacker bits/claim:

| attacker | raw | ideas-only | +L4 |
|---|---|---|---|
| dashscope:qwen-plus | 2.21 [1.94, 2.50] | 1.00 [0.72, 1.27] | 1.00 [0.79, 1.21] |
| dashscope:kimi-k3 | 2.31 [2.04, 2.61] | 0.95 [0.67, 1.23] | 0.87 [0.66, 1.10] |

Memorisation probe (18 items): bits/excerpt 1.53 [1.28, 1.84], excess over ideas-only 0.49 [0.17, 0.80], meeting (year+month) hit rate 11% (dashscope:qwen-plus 1, dashscope:kimi-k3 1) → no memorisation flag

## v5 hard zeros (METHOD §10.4–§10.5)

| quantity | value | threshold |
|---|---|---|
| T1 v5 (private names / bound vocatives / private seats / bound orgs) | 0 (0 / 0 / 0 / 0) | 0 |
| · of which public persons' names in a bound position (reveal / mask miss) | 0 | |
| · of which attributable to a granted reveal | 0 | |
| T2 v5 sensitive long quotes | 0 | 0 |
| T2 plain long quotes (reported) | 28 | — |
| T6 v5 outsider-named (P10: public topic mentions are no evidence) | 0 | 0 |
| T6 v3 outsider-named (reported) | 0 | — |
| selfTraits (reported) | 0 | — |

## reveal_name (METHOD §10.2)

protocol: two-pass (requests ride the L3 JSON; code adjudicates; grants applied after every other layer)

| quantity | value |
|---|---|
| +L4 records with pseudonyms | 43 / 54 |
| requests (per record) | 3 (0.07) |
| granted (rate) | 0 (0.0%) |
| denied by reason | private 2, bound-position 1 |
| granted by kind (roster speakers / other persons) | 0 / 0 |
| token occurrences unmasked | 0 |
| granted persons re-masked in a bound / attributive position (post-check) | 0 |
| tokens in bound positions generalised | 1 |
| post-check re-masked names | 0 |
| persons tokenised (speakers / others / public, ASR variants) | 322 / 323 / 439, 0 |


## Calibration ECE (10 bins, top-1)

{
 "dashscope:qwen-plus": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.06746065573770389,
    "n": 366,
    "acc": 0.8661202185792349,
    "conf": 0.9155480874316938
   },
   "after": {
    "ece": 0.04543976593424673,
    "n": 366,
    "acc": 0.8661202185792349,
    "conf": 0.8426735587406139
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.23966338797814207,
    "n": 366,
    "acc": 0.40437158469945356,
    "conf": 0.644034972677595
   },
   "after": {
    "ece": 0.18287453243260468,
    "n": 366,
    "acc": 0.40437158469945356,
    "conf": 0.5822817404736009
   }
  },
  "+L4": {
   "n": 1033,
   "before": {
    "ece": 0.23776640851887704,
    "n": 1033,
    "acc": 0.4133591481122943,
    "conf": 0.6511255566311716
   },
   "after": {
    "ece": 0.17919538325413464,
    "n": 1033,
    "acc": 0.4133591481122943,
    "conf": 0.5904857590912223
   }
  }
 },
 "dashscope:kimi-k3": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.05778688524590205,
    "n": 366,
    "acc": 0.8770491803278688,
    "conf": 0.8769125683060099
   },
   "after": {
    "ece": 0.07269107779131007,
    "n": 366,
    "acc": 0.8770491803278688,
    "conf": 0.8503247485549011
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.041775956284152954,
    "n": 366,
    "acc": 0.4562841530054645,
    "conf": 0.4772950819672128
   },
   "after": {
    "ece": 0.054029200139573165,
    "n": 366,
    "acc": 0.4562841530054645,
    "conf": 0.45917315117249635
   }
  },
  "+L4": {
   "n": 1033,
   "before": {
    "ece": 0.06718547918683491,
    "n": 1033,
    "acc": 0.42884801548886736,
    "conf": 0.4599250726040659
   },
   "after": {
    "ece": 0.07121600076290689,
    "n": 1033,
    "acc": 0.42884801548886736,
    "conf": 0.44287410670809685
   }
  }
 }
}
`
