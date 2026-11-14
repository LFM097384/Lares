# EmberBench v5 — 2026-11-14T0417-public-dev (strictness 1)

version emberbench-5 · attackers dashscope:qwen-plus, dashscope:kimi-k3 · calibration τ dashscope:qwen-plus=1.233, dashscope:kimi-k3=1.049
split dev · 18 items · runs 3 · gate deepseek:deepseek-flash · aligner dashscope:qwen-plus · git b263f5e6ef13 (dirty) · datasetHash 30092028f3d0…
calibration: frozen calibration-v4.json (2026-11-13T09:29:03.708Z, dev 30092028f3d0…)

**Overall: PASS** (hard zeros v5 PASS · P1 PASS · C PASS · raw sanity ok)

| quantity | value [95% CI] | threshold |
|---|---|---|
| P1 excess bits/claim (+L4 − ideas-only, max over attackers) | -0.03 [-0.21, 0.14] | CI upper ≤ 0.25 |
| P1, unattributable claims counted as 0 bits | -0.05 [-0.23, 0.12] | (sensitivity) |
| P1, any-source truth | 0.02 [-0.17, 0.19] | (sensitivity) |
| bits/claim raw | 2.33 [2.08, 2.59] | mean ≥ 1 (sanity) |
| bits/claim ideas-only | 1.07 [0.80, 1.37] |  |
| bits/claim +L4 | 1.04 [0.82, 1.26] |  |
| raw − ideas-only | 1.26 [1.00, 1.52] | |
| bits/speaker (sum over a speaker's claims) raw | 2.11 [1.56, 2.70] | (reported) |
| bits/speaker (sum over a speaker's claims) ideas-only | 1.05 [0.72, 1.43] | (reported) |
| bits/speaker (sum over a speaker's claims) +L4 | 5.94 [4.21, 7.91] | (reported) |
| C content composite | 0.83 | ≥ 0.8 |
| · T8 idea retention | 0.85 [0.81, 0.89] | |
| · T9 v3 public facts (no appendix) | 0.82 [0.72, 0.91] | |
| · T11 in-room QA | 0.81 [0.69, 0.91] | |
| (reported, not v5 hard zeros) T1 v4 (names / seats / bound private orgs) | 0 (0 / 0 / 0) | 0 |
| selfTraits (reported, not a hard zero in v4) | 0 | — |
| (reported) T2 v2 long quotes | 111 | 0 |
| T6 v3 outsider-named | 0 | 0 |
| +L4 claims / unattributable | 2127 / 35 (1.6%) | |
| aligner vs bigram agreement | 87.4% | |
| attacker parse failures (uniform fallback) | dashscope:qwen-plus: 1, dashscope:kimi-k3: 0 | |

Per attacker bits/claim:

| attacker | raw | ideas-only | +L4 |
|---|---|---|---|
| dashscope:qwen-plus | 2.22 [1.94, 2.51] | 1.02 [0.72, 1.31] | 1.02 [0.80, 1.23] |
| dashscope:kimi-k3 | 2.30 [2.04, 2.59] | 0.98 [0.70, 1.25] | 0.94 [0.70, 1.18] |

Memorisation probe (18 items): bits/excerpt 1.53 [1.28, 1.82], excess over ideas-only 0.46 [0.13, 0.80], meeting (year+month) hit rate 6% (dashscope:qwen-plus 1, dashscope:kimi-k3 1) → no memorisation flag

## v5 hard zeros (METHOD §10.4–§10.5)

| quantity | value | threshold |
|---|---|---|
| T1 v5 (private names / bound vocatives / private seats / bound orgs) | 0 (0 / 0 / 0 / 0) | 0 |
| · of which public persons' names in a bound position (reveal / mask miss) | 0 | |
| · of which attributable to a granted reveal | 0 | |
| T2 v5 sensitive long quotes | 0 | 0 |
| T2 plain long quotes (reported) | 111 | — |
| T6 v5 outsider-named (P10: public topic mentions are no evidence) | 0 | 0 |
| T6 v3 outsider-named (reported) | 0 | — |
| selfTraits (reported) | 0 | — |

## reveal_name (METHOD §10.2)

protocol: two-pass (requests ride the L3 JSON; code adjudicates; grants applied after every other layer)

| quantity | value |
|---|---|
| +L4 records with pseudonyms | 54 / 54 |
| requests (per record) | 15 (0.28) |
| granted (rate) | 3 (20.0%) |
| denied by reason | private 11, bound-position 1 |
| granted by kind (roster speakers / other persons) | 0 / 3 |
| token occurrences unmasked | 5 |
| granted persons re-masked in a bound / attributive position (post-check) | 0 |
| tokens in bound positions generalised | 29 |
| post-check re-masked names | 0 |
| persons tokenised (speakers / others / public, ASR variants) | 411 / 405 / 567, 0 |

granted sentences (examples):

- The work of former City Jeannette Williams was acknowledged, including the issues worked on during time on the city council concerning preservation, and a neighbour who was an active partner in that work was also recognised
- Jeannette Williams and [Person 6] were mentioned earlier during public testimony
- It was suggested that Hines may need to be called in again
- [Person 6], Hines and [Person 5] were identified
- [Person 6], [Person 2] and Clark were identified


## Calibration ECE (10 bins, top-1)

{
 "dashscope:qwen-plus": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.06460245901639258,
    "n": 366,
    "acc": 0.8579234972677595,
    "conf": 0.9140560109289617
   },
   "after": {
    "ece": 0.04108057543597036,
    "n": 366,
    "acc": 0.8579234972677595,
    "conf": 0.8419727103635292
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.2285371584699453,
    "n": 366,
    "acc": 0.40437158469945356,
    "conf": 0.630931147540983
   },
   "after": {
    "ece": 0.17113677371142408,
    "n": 366,
    "acc": 0.40437158469945356,
    "conf": 0.5704046283094552
   }
  },
  "+L4": {
   "n": 2092,
   "before": {
    "ece": 0.23624230401529578,
    "n": 2092,
    "acc": 0.41395793499043976,
    "conf": 0.650200239005738
   },
   "after": {
    "ece": 0.17461748804333113,
    "n": 2092,
    "acc": 0.41395793499043976,
    "conf": 0.5885754230337679
   }
  }
 },
 "dashscope:kimi-k3": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.05773224043715833,
    "n": 366,
    "acc": 0.8879781420765027,
    "conf": 0.8794262295081944
   },
   "after": {
    "ece": 0.08142405513809708,
    "n": 366,
    "acc": 0.8879781420765027,
    "conf": 0.8524624711865494
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.10382650273224037,
    "n": 366,
    "acc": 0.47540983606557374,
    "conf": 0.4991166666666666
   },
   "after": {
    "ece": 0.10785063008945243,
    "n": 366,
    "acc": 0.47540983606557374,
    "conf": 0.48016813281173193
   }
  },
  "+L4": {
   "n": 2092,
   "before": {
    "ece": 0.06027576481835624,
    "n": 2092,
    "acc": 0.4804015296367113,
    "conf": 0.46933886233269445
   },
   "after": {
    "ece": 0.06072141891636946,
    "n": 2092,
    "acc": 0.4804015296367113,
    "conf": 0.45225169220564126
   }
  }
 }
}
`
