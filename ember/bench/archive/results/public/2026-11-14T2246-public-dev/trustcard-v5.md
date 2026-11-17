# EmberBench v5 — 2026-11-14T2246-public-dev (strictness 1)

version emberbench-5 · attackers dashscope:qwen-plus, dashscope:kimi-k3 · calibration τ dashscope:qwen-plus=1.233, dashscope:kimi-k3=1.049
split dev · 18 items · runs 3 · gate chatgpt:gpt-5.6-luna · aligner dashscope:qwen-plus · git 1541d3950588 · datasetHash 30092028f3d0…
calibration: frozen calibration-v4.json (2026-11-13T09:29:03.708Z, dev 30092028f3d0…)

**Overall: FAIL** (hard zeros v5 PASS · P1 PASS · C FAIL · raw sanity ok)

| quantity | value [95% CI] | threshold |
|---|---|---|
| P1 excess bits/claim (+L4 − ideas-only, max over attackers) | -0.03 [-0.25, 0.20] | CI upper ≤ 0.25 |
| P1, unattributable claims counted as 0 bits | -0.06 [-0.30, 0.17] | (sensitivity) |
| P1, any-source truth | 0.07 [-0.17, 0.33] | (sensitivity) |
| bits/claim raw | 2.34 [2.07, 2.63] | mean ≥ 1 (sanity) |
| bits/claim ideas-only | 1.07 [0.79, 1.40] |  |
| bits/claim +L4 | 1.04 [0.81, 1.29] |  |
| raw − ideas-only | 1.27 [0.99, 1.52] | |
| bits/speaker (sum over a speaker's claims) raw | 2.14 [1.58, 2.75] | (reported) |
| bits/speaker (sum over a speaker's claims) ideas-only | 1.05 [0.70, 1.45] | (reported) |
| bits/speaker (sum over a speaker's claims) +L4 | 3.41 [2.37, 4.58] | (reported) |
| C content composite | 0.74 | ≥ 0.8 |
| · T8 idea retention | 0.66 [0.57, 0.73] | |
| · T9 v3 public facts (no appendix) | 0.68 [0.55, 0.79] | |
| · T11 in-room QA | 0.87 [0.77, 0.96] | |
| (reported, not v5 hard zeros) T1 v4 (names / seats / bound private orgs) | 0 (0 / 0 / 0) | 0 |
| selfTraits (reported, not a hard zero in v4) | 0 | — |
| (reported) T2 v2 long quotes | 30 | 0 |
| T6 v3 outsider-named | 0 | 0 |
| +L4 claims / unattributable | 1302 / 41 (3.1%) | |
| aligner vs bigram agreement | 81.9% | |
| attacker parse failures (uniform fallback) | dashscope:qwen-plus: 0, dashscope:kimi-k3: 0 | |

Per attacker bits/claim:

| attacker | raw | ideas-only | +L4 |
|---|---|---|---|
| dashscope:qwen-plus | 2.23 [1.96, 2.52] | 0.96 [0.67, 1.26] | 1.01 [0.78, 1.24] |
| dashscope:kimi-k3 | 2.31 [2.03, 2.61] | 0.98 [0.66, 1.31] | 0.93 [0.71, 1.18] |

Memorisation probe (18 items): bits/excerpt 1.68 [1.40, 1.97], excess over ideas-only 0.61 [0.26, 0.93], meeting (year+month) hit rate 11% (dashscope:qwen-plus 1, dashscope:kimi-k3 2) → no memorisation flag

## v5 hard zeros (METHOD §10.4–§10.5)

| quantity | value | threshold |
|---|---|---|
| T1 v5 (private names / bound vocatives / private seats / bound orgs) | 0 (0 / 0 / 0 / 0) | 0 |
| · of which public persons' names in a bound position (reveal / mask miss) | 0 | |
| · of which attributable to a granted reveal | 0 | |
| T2 v5 sensitive long quotes | 0 | 0 |
| T2 plain long quotes (reported) | 30 | — |
| T6 v5 outsider-named (P10: public topic mentions are no evidence) | 0 | 0 |
| T6 v3 outsider-named (reported) | 0 | — |
| selfTraits (reported) | 0 | — |

## reveal_name (METHOD §10.2)

protocol: two-pass (requests ride the L3 JSON; code adjudicates; grants applied after every other layer)

| quantity | value |
|---|---|
| +L4 records with pseudonyms | 54 / 54 |
| requests (per record) | 7 (0.13) |
| granted (rate) | 0 (0.0%) |
| denied by reason | private 7 |
| granted by kind (roster speakers / other persons) | 0 / 0 |
| token occurrences unmasked | 0 |
| granted persons re-masked in a bound / attributive position (post-check) | 0 |
| tokens in bound positions generalised | 3 |
| post-check re-masked names | 0 |
| persons tokenised (speakers / others / public, ASR variants) | 411 / 405 / 567, 0 |


## Calibration ECE (10 bins, top-1)

{
 "dashscope:qwen-plus": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.07057978142076432,
    "n": 366,
    "acc": 0.8688524590163934,
    "conf": 0.919420218579235
   },
   "after": {
    "ece": 0.055002277113397155,
    "n": 366,
    "acc": 0.8688524590163934,
    "conf": 0.8475691575682552
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.24266366120218585,
    "n": 366,
    "acc": 0.39344262295081966,
    "conf": 0.6323691256830595
   },
   "after": {
    "ece": 0.18530816193828165,
    "n": 366,
    "acc": 0.39344262295081966,
    "conf": 0.5713175366920191
   }
  },
  "+L4": {
   "n": 1261,
   "before": {
    "ece": 0.22151062648691527,
    "n": 1261,
    "acc": 0.4091990483743061,
    "conf": 0.6307096748612224
   },
   "after": {
    "ece": 0.16220123068611933,
    "n": 1261,
    "acc": 0.4091990483743061,
    "conf": 0.5714002790604253
   }
  }
 },
 "dashscope:kimi-k3": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.03256830601092916,
    "n": 366,
    "acc": 0.8770491803278688,
    "conf": 0.8847540983606552
   },
   "after": {
    "ece": 0.06050342252990064,
    "n": 366,
    "acc": 0.8770491803278688,
    "conf": 0.8586294542660543
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.08183060109289615,
    "n": 366,
    "acc": 0.44808743169398907,
    "conf": 0.49631147540983606
   },
   "after": {
    "ece": 0.06331795057053874,
    "n": 366,
    "acc": 0.44808743169398907,
    "conf": 0.47799202676709435
   }
  },
  "+L4": {
   "n": 1261,
   "before": {
    "ece": 0.08114203013481405,
    "n": 1261,
    "acc": 0.464710547184774,
    "conf": 0.4579169706582081
   },
   "after": {
    "ece": 0.06763475828877559,
    "n": 1261,
    "acc": 0.464710547184774,
    "conf": 0.44094420447657207
   }
  }
 }
}
`
