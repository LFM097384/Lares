# EmberBench v5 — 2026-11-15T0408-public-dev (strictness 1)

version emberbench-5 · attackers dashscope:qwen-plus, dashscope:kimi-k3 · calibration τ dashscope:qwen-plus=1.233, dashscope:kimi-k3=1.049
split dev · 18 items · runs 3 · gate chatgpt:gpt-6-astra · aligner dashscope:qwen-plus · git 1541d3950588 (dirty) · datasetHash 30092028f3d0…
calibration: frozen calibration-v4.json (2026-11-13T09:29:03.708Z, dev 30092028f3d0…)

**Overall: FAIL** (hard zeros v5 PASS · P1 PASS · C FAIL · raw sanity ok)

| quantity | value [95% CI] | threshold |
|---|---|---|
| P1 excess bits/claim (+L4 − ideas-only, max over attackers) | 0.03 [-0.19, 0.24] | CI upper ≤ 0.25 |
| P1, unattributable claims counted as 0 bits | 0.01 [-0.21, 0.22] | (sensitivity) |
| P1, any-source truth | 0.05 [-0.18, 0.25] | (sensitivity) |
| bits/claim raw | 2.34 [2.08, 2.60] | mean ≥ 1 (sanity) |
| bits/claim ideas-only | 1.04 [0.77, 1.37] |  |
| bits/claim +L4 | 1.09 [0.81, 1.46] |  |
| raw − ideas-only | 1.30 [1.02, 1.58] | |
| bits/speaker (sum over a speaker's claims) raw | 2.10 [1.54, 2.70] | (reported) |
| bits/speaker (sum over a speaker's claims) ideas-only | 1.02 [0.70, 1.42] | (reported) |
| bits/speaker (sum over a speaker's claims) +L4 | 1.86 [1.06, 2.83] | (reported) |
| C content composite | 0.44 | ≥ 0.8 |
| · T8 idea retention | 0.27 [0.21, 0.32] | |
| · T9 v3 public facts (no appendix) | 0.29 [0.23, 0.36] | |
| · T11 in-room QA | 0.77 [0.64, 0.90] | |
| (reported, not v5 hard zeros) T1 v4 (names / seats / bound private orgs) | 0 (0 / 0 / 0) | 0 |
| selfTraits (reported, not a hard zero in v4) | 0 | — |
| (reported) T2 v2 long quotes | 20 | 0 |
| T6 v3 outsider-named | 0 | 0 |
| +L4 claims / unattributable | 609 / 9 (1.5%) | |
| aligner vs bigram agreement | 88.6% | |
| attacker parse failures (uniform fallback) | dashscope:qwen-plus: 6, dashscope:kimi-k3: 0 | |

Per attacker bits/claim:

| attacker | raw | ideas-only | +L4 |
|---|---|---|---|
| dashscope:qwen-plus | 2.19 [1.90, 2.49] | 0.97 [0.68, 1.27] | 1.03 [0.77, 1.33] |
| dashscope:kimi-k3 | 2.30 [2.03, 2.60] | 0.95 [0.66, 1.24] | 1.00 [0.71, 1.36] |

Memorisation probe (18 items): bits/excerpt 1.55 [1.29, 1.85], excess over ideas-only 0.51 [0.17, 0.86], meeting (year+month) hit rate 11% (dashscope:qwen-plus 1, dashscope:kimi-k3 1) → no memorisation flag

## v5 hard zeros (METHOD §10.4–§10.5)

| quantity | value | threshold |
|---|---|---|
| T1 v5 (private names / bound vocatives / private seats / bound orgs) | 0 (0 / 0 / 0 / 0) | 0 |
| · of which public persons' names in a bound position (reveal / mask miss) | 0 | |
| · of which attributable to a granted reveal | 0 | |
| T2 v5 sensitive long quotes | 0 | 0 |
| T2 plain long quotes (reported) | 20 | — |
| T6 v5 outsider-named (P10: public topic mentions are no evidence) | 0 | 0 |
| T6 v3 outsider-named (reported) | 0 | — |
| selfTraits (reported) | 0 | — |

## reveal_name (METHOD §10.2)

protocol: two-pass (requests ride the L3 JSON; code adjudicates; grants applied after every other layer)

| quantity | value |
|---|---|
| +L4 records with pseudonyms | 17 / 54 |
| requests (per record) | 0 (0.00) |
| granted (rate) | 0 (—) |
| denied by reason | — |
| granted by kind (roster speakers / other persons) | 0 / 0 |
| token occurrences unmasked | 0 |
| granted persons re-masked in a bound / attributive position (post-check) | 0 |
| tokens in bound positions generalised | 0 |
| post-check re-masked names | 0 |
| persons tokenised (speakers / others / public, ASR variants) | 113 / 133 / 166, 0 |


## Calibration ECE (10 bins, top-1)

{
 "dashscope:qwen-plus": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.06570573770491696,
    "n": 366,
    "acc": 0.855191256830601,
    "conf": 0.9037931693989071
   },
   "after": {
    "ece": 0.04037535738462977,
    "n": 366,
    "acc": 0.855191256830601,
    "conf": 0.8317414645448395
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.2703377049180328,
    "n": 366,
    "acc": 0.3770491803278688,
    "conf": 0.6473868852459009
   },
   "after": {
    "ece": 0.21530473599816757,
    "n": 366,
    "acc": 0.3770491803278688,
    "conf": 0.5851182870117632
   }
  },
  "+L4": {
   "n": 600,
   "before": {
    "ece": 0.1662166666666668,
    "n": 600,
    "acc": 0.5066666666666667,
    "conf": 0.6703833333333333
   },
   "after": {
    "ece": 0.10625849511232993,
    "n": 600,
    "acc": 0.5066666666666667,
    "conf": 0.6105448043944487
   }
  }
 },
 "dashscope:kimi-k3": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.03058606557377065,
    "n": 366,
    "acc": 0.8770491803278688,
    "conf": 0.8840767759562825
   },
   "after": {
    "ece": 0.0482095525784674,
    "n": 366,
    "acc": 0.8770491803278688,
    "conf": 0.8573241864745595
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.0740871584699453,
    "n": 366,
    "acc": 0.4562841530054645,
    "conf": 0.481464207650273
   },
   "after": {
    "ece": 0.08286964657812652,
    "n": 366,
    "acc": 0.4562841530054645,
    "conf": 0.4634832456090819
   }
  },
  "+L4": {
   "n": 600,
   "before": {
    "ece": 0.08412666666666667,
    "n": 600,
    "acc": 0.5483333333333333,
    "conf": 0.5239600000000002
   },
   "after": {
    "ece": 0.0976443769702816,
    "n": 600,
    "acc": 0.5483333333333333,
    "conf": 0.5041690543640513
   }
  }
 }
}
`
