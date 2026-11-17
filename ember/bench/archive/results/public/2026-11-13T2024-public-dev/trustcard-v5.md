# EmberBench v5 — 2026-11-13T2024-public-dev (strictness 1)

version emberbench-5 · attackers dashscope:qwen-plus, dashscope:kimi-k3 · calibration τ dashscope:qwen-plus=1.233, dashscope:kimi-k3=1.049
split dev · 18 items · runs 3 · gate deepseek:deepseek-flash · aligner dashscope:qwen-plus · git fdfea0fc9605 (dirty) · datasetHash 30092028f3d0…
calibration: frozen calibration-v4.json (2026-11-13T09:29:03.708Z, dev 30092028f3d0…)

**Overall: FAIL** (hard zeros v5 FAIL · P1 FAIL · C FAIL · raw sanity ok)

| quantity | value [95% CI] | threshold |
|---|---|---|
| P1 excess bits/claim (+L4 − ideas-only, max over attackers) | 0.25 [0.03, 0.46] | CI upper ≤ 0.25 |
| P1, unattributable claims counted as 0 bits | 0.21 [-0.02, 0.42] | (sensitivity) |
| P1, any-source truth | 0.31 [0.10, 0.50] | (sensitivity) |
| bits/claim raw | 1.90 [1.61, 2.23] | mean ≥ 1 (sanity) |
| bits/claim ideas-only | 0.80 [0.61, 1.00] |  |
| bits/claim +L4 | 1.05 [0.79, 1.33] |  |
| raw − ideas-only | 1.10 [0.82, 1.40] | |
| bits/speaker (sum over a speaker's claims) raw | 1.71 [1.26, 2.21] | (reported) |
| bits/speaker (sum over a speaker's claims) ideas-only | 0.79 [0.55, 1.06] | (reported) |
| bits/speaker (sum over a speaker's claims) +L4 | 4.16 [2.97, 5.48] | (reported) |
| C content composite | 0.75 | ≥ 0.8 |
| · T8 idea retention | 0.83 [0.76, 0.89] | |
| · T9 v3 public facts (no appendix) | 0.65 [0.56, 0.74] | |
| · T11 in-room QA | 0.78 [0.65, 0.90] | |
| (reported, not v5 hard zeros) T1 v4 (names / seats / bound private orgs) | 4 (1 / 1 / 2) | 0 |
| selfTraits (reported, not a hard zero in v4) | 0 | — |
| (reported) T2 v2 long quotes | 95 | 0 |
| T6 v3 outsider-named | 1 | 0 |
| +L4 claims / unattributable | 1609 / 90 (5.6%) | |
| aligner vs bigram agreement | 87.0% | |
| attacker parse failures (uniform fallback) | dashscope:qwen-plus: 215, dashscope:kimi-k3: 215 | |

Per attacker bits/claim:

| attacker | raw | ideas-only | +L4 |
|---|---|---|---|
| dashscope:qwen-plus | 1.82 [1.53, 2.12] | 0.73 [0.52, 0.93] | 1.01 [0.78, 1.24] |
| dashscope:kimi-k3 | 1.88 [1.56, 2.21] | 0.73 [0.54, 0.92] | 0.96 [0.70, 1.23] |

Memorisation probe (18 items): bits/excerpt 1.60 [1.34, 1.91], excess over ideas-only 0.80 [0.48, 1.11], meeting (year+month) hit rate 6% (dashscope:qwen-plus 1, dashscope:kimi-k3 0) → no memorisation flag

## v5 hard zeros (METHOD §10.4–§10.5)

| quantity | value | threshold |
|---|---|---|
| T1 v5 (private names / bound vocatives / private seats / bound orgs) | 7 (0 / 5 / 0 / 2) | 0 |
| · of which public persons' names in a bound position (reveal / mask miss) | 4 | |
| T2 v5 sensitive long quotes | 0 | 0 |
| T2 plain long quotes (reported) | 95 | — |
| T6 v3 outsider-named | 1 | 0 |
| selfTraits (reported) | 0 | — |

## reveal_name (METHOD §10.2)

protocol: two-pass (requests ride the L3 JSON; code adjudicates; grants applied after every other layer)

| quantity | value |
|---|---|
| +L4 records with pseudonyms | 42 / 54 |
| requests (per record) | 8 (0.19) |
| granted (rate) | 1 (12.5%) |
| denied by reason | private 7 |
| token occurrences unmasked | 1 |
| tokens in bound positions generalised | 3 |
| post-check re-masked names | 0 |
| persons tokenised (speakers / others / public, ASR variants) | 306 / 322 / 440, 0 |


## Calibration ECE (10 bins, top-1)

{
 "dashscope:qwen-plus": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.07707459016393378,
    "n": 366,
    "acc": 0.7213114754098361,
    "conf": 0.7778418032786878
   },
   "after": {
    "ece": 0.05083219708559733,
    "n": 366,
    "acc": 0.7213114754098361,
    "conf": 0.7187452216220377
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.22162650273224038,
    "n": 366,
    "acc": 0.319672131147541,
    "conf": 0.5333833333333331
   },
   "after": {
    "ece": 0.17635023048597948,
    "n": 366,
    "acc": 0.319672131147541,
    "conf": 0.48518611120276084
   }
  },
  "+L4": {
   "n": 1519,
   "before": {
    "ece": 0.21839374588545057,
    "n": 1519,
    "acc": 0.4206714944042133,
    "conf": 0.6390652402896664
   },
   "after": {
    "ece": 0.15837588620947546,
    "n": 1519,
    "acc": 0.4206714944042133,
    "conf": 0.5790473806136864
   }
  }
 },
 "dashscope:kimi-k3": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.0306128415300549,
    "n": 366,
    "acc": 0.73224043715847,
    "conf": 0.7519265027322397
   },
   "after": {
    "ece": 0.048443484903832296,
    "n": 366,
    "acc": 0.73224043715847,
    "conf": 0.7301541890271184
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.05864071038251346,
    "n": 366,
    "acc": 0.40437158469945356,
    "conf": 0.40481393442622915
   },
   "after": {
    "ece": 0.02506797949703336,
    "n": 366,
    "acc": 0.40437158469945356,
    "conf": 0.39063373929658723
   }
  },
  "+L4": {
   "n": 1519,
   "before": {
    "ece": 0.039498551678735755,
    "n": 1519,
    "acc": 0.4739960500329164,
    "conf": 0.46203851217906516
   },
   "after": {
    "ece": 0.05185459042844249,
    "n": 1519,
    "acc": 0.4739960500329164,
    "conf": 0.44466222031223407
   }
  }
 }
}
`
