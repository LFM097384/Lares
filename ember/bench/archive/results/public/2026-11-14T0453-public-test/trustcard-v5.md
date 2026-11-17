# EmberBench v5 — 2026-11-14T0453-public-test (strictness 1)

version emberbench-5 · attackers dashscope:qwen-plus, dashscope:kimi-k3 · calibration τ dashscope:qwen-plus=1.233, dashscope:kimi-k3=1.049
split test · 60 items · runs 3 · gate deepseek:deepseek-flash · aligner dashscope:qwen-plus · git 06c892c57d99 · datasetHash a21986096921…
calibration: frozen calibration-v4.json (2026-11-13T09:29:03.708Z, dev 30092028f3d0…)

**Overall: FAIL** (hard zeros v5 FAIL · P1 PASS · C FAIL · raw sanity ok)

| quantity | value [95% CI] | threshold |
|---|---|---|
| P1 excess bits/claim (+L4 − ideas-only, max over attackers) | -0.14 [-0.28, -0.00] | CI upper ≤ 0.25 |
| P1, unattributable claims counted as 0 bits | -0.15 [-0.29, -0.01] | (sensitivity) |
| P1, any-source truth | -0.08 [-0.21, 0.05] | (sensitivity) |
| bits/claim raw | 2.24 [2.15, 2.33] | mean ≥ 1 (sanity) |
| bits/claim ideas-only | 0.90 [0.79, 1.05] |  |
| bits/claim +L4 | 0.85 [0.75, 0.99] |  |
| raw − ideas-only | 1.34 [1.19, 1.46] | |
| bits/speaker (sum over a speaker's claims) raw | 2.77 [2.41, 3.12] | (reported) |
| bits/speaker (sum over a speaker's claims) ideas-only | 1.20 [0.97, 1.42] | (reported) |
| bits/speaker (sum over a speaker's claims) +L4 | 1.30 [1.03, 1.59] | (reported) |
| C content composite | 0.42 | ≥ 0.8 |
| · T8 idea retention | 0.19 [0.15, 0.22] | |
| · T9 v3 public facts (no appendix) | 0.18 [0.15, 0.21] | |
| · T11 in-room QA | 0.88 [0.80, 0.94] | |
| (reported, not v5 hard zeros) T1 v4 (names / seats / bound private orgs) | 9 (6 / 3 / 0) | 0 |
| selfTraits (reported, not a hard zero in v4) | 6 | — |
| (reported) T2 v2 long quotes | 93 | 0 |
| T6 v3 outsider-named | 4 | 0 |
| +L4 claims / unattributable | 1510 / 23 (1.5%) | |
| aligner vs bigram agreement | 84.0% | |
| attacker parse failures (uniform fallback) | dashscope:qwen-plus: 0, dashscope:kimi-k3: 0 | |

Per attacker bits/claim:

| attacker | raw | ideas-only | +L4 |
|---|---|---|---|
| dashscope:qwen-plus | 2.12 [2.01, 2.22] | 0.81 [0.68, 0.95] | 0.77 [0.66, 0.89] |
| dashscope:kimi-k3 | 2.20 [2.10, 2.29] | 0.78 [0.66, 0.91] | 0.77 [0.65, 0.89] |

## v5 hard zeros (METHOD §10.4–§10.5)

| quantity | value | threshold |
|---|---|---|
| T1 v5 (private names / bound vocatives / private seats / bound orgs) | 5 (2 / 3 / 0 / 0) | 0 |
| · of which public persons' names in a bound position (reveal / mask miss) | 0 | |
| · of which attributable to a granted reveal | 0 | |
| T2 v5 sensitive long quotes | 1 | 0 |
| T2 plain long quotes (reported) | 93 | — |
| T6 v5 outsider-named (P10: public topic mentions are no evidence) | 0 | 0 |
| T6 v3 outsider-named (reported) | 4 | — |
| selfTraits (reported) | 6 | — |

## reveal_name (METHOD §10.2)

protocol: two-pass (requests ride the L3 JSON; code adjudicates; grants applied after every other layer)

| quantity | value |
|---|---|
| +L4 records with pseudonyms | 40 / 180 |
| requests (per record) | 9 (0.23) |
| granted (rate) | 7 (77.8%) |
| denied by reason | private 2 |
| granted by kind (roster speakers / other persons) | 1 / 6 |
| token occurrences unmasked | 8 |
| granted persons re-masked in a bound / attributive position (post-check) | 1 |
| tokens in bound positions generalised | 12 |
| post-check re-masked names | 0 |
| persons tokenised (speakers / others / public, ASR variants) | 236 / 241 / 289, 6 |

granted sentences (examples):

- the answer given was Tony and one other member
- It was resolved that Ashcraft, as mayor of the city of Alameda, proclaim [date] to 13, 2019 to be Alameda County Victims Rights Week and reaffirm the commitment to respect and enforce victims' rights and address victims' needs during victim
- A motion to postpone was attributed to Herndon
- Appreciation was expressed for Richardson bringing the matter forward
- The ordinance was sponsored by council members Steven Neal and [Person 1] in July 2012 and adopted by City Council on August six, 2013
- The ordinance was sponsored by council members [Speaker 7] and Austin in July 2012 and adopted by City Council on August six, 2013
- Item 11 is a report from the office of Steven Neal and [Person 2] recommending that a report on the status of the alcohol nuisance abatement ordinance be received and filed
- In 2012, Austin and another council member embarked upon an initiative to address public safety, health and safety issues in North Long Beach


## Calibration ECE (10 bins, top-1)

{
 "dashscope:qwen-plus": {
  "raw": {
   "n": 1284,
   "before": {
    "ece": 0.02523940809969648,
    "n": 1284,
    "acc": 0.9182242990654206,
    "conf": 0.9183534267912893
   },
   "after": {
    "ece": 0.06849121067570041,
    "n": 1284,
    "acc": 0.9182242990654206,
    "conf": 0.8497330883897168
   }
  },
  "ideas-only": {
   "n": 1284,
   "before": {
    "ece": 0.2794749999999998,
    "n": 1284,
    "acc": 0.38161993769470404,
    "conf": 0.6610949376947064
   },
   "after": {
    "ece": 0.21738537184304396,
    "n": 1284,
    "acc": 0.38161993769470404,
    "conf": 0.5990053095377488
   }
  },
  "+L4": {
   "n": 1487,
   "before": {
    "ece": 0.262098184263618,
    "n": 1487,
    "acc": 0.37390719569603226,
    "conf": 0.6360053799596526
   },
   "after": {
    "ece": 0.20365989364450054,
    "n": 1487,
    "acc": 0.37390719569603226,
    "conf": 0.5775670893405339
   }
  }
 },
 "dashscope:kimi-k3": {
  "raw": {
   "n": 1284,
   "before": {
    "ece": 0.05737538940810162,
    "n": 1284,
    "acc": 0.9509345794392523,
    "conf": 0.8935591900311568
   },
   "after": {
    "ece": 0.08344129392522018,
    "n": 1284,
    "acc": 0.9509345794392523,
    "conf": 0.8674932855140335
   }
  },
  "ideas-only": {
   "n": 1284,
   "before": {
    "ece": 0.06809190031152651,
    "n": 1284,
    "acc": 0.43068535825545173,
    "conf": 0.4839174454828661
   },
   "after": {
    "ece": 0.06056551019828936,
    "n": 1284,
    "acc": 0.43068535825545173,
    "conf": 0.46670044228723256
   }
  },
  "+L4": {
   "n": 1487,
   "before": {
    "ece": 0.05145198386012099,
    "n": 1487,
    "acc": 0.429724277067922,
    "conf": 0.4718622057834565
   },
   "after": {
    "ece": 0.03602704289644046,
    "n": 1487,
    "acc": 0.429724277067922,
    "conf": 0.45481933826522297
   }
  }
 }
}
`
