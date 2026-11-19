# EmberBench v5 — 2026-11-17T0037-public-test (strictness 1)

version emberbench-5 · attackers dashscope:qwen-plus, dashscope:kimi-k3 · calibration τ dashscope:qwen-plus=1.233, dashscope:kimi-k3=1.049
split test · 60 items · runs 3 · gate deepseek:deepseek-flash · aligner dashscope:qwen-plus · git c39d66bef23f · datasetHash a21986096921…
calibration: frozen calibration-v4.json (2026-11-13T09:29:03.708Z, dev 30092028f3d0…)

**Overall: FAIL** (hard zeros v5 FAIL · P1 PASS · C PASS · raw sanity ok)

| quantity | value [95% CI] | threshold |
|---|---|---|
| P1 excess bits/claim (+L4 − ideas-only, max over attackers) | -0.03 [-0.14, 0.07] | CI upper ≤ 0.25 |
| P1, unattributable claims counted as 0 bits | -0.06 [-0.17, 0.03] | (sensitivity) |
| P1, any-source truth | 0.03 [-0.08, 0.12] | (sensitivity) |
| bits/claim raw | 2.22 [2.13, 2.32] | mean ≥ 1 (sanity) |
| bits/claim ideas-only | 0.90 [0.79, 1.05] |  |
| bits/claim +L4 | 0.88 [0.80, 0.95] |  |
| raw − ideas-only | 1.31 [1.17, 1.44] | |
| bits/speaker (sum over a speaker's claims) raw | 2.74 [2.39, 3.08] | (reported) |
| bits/speaker (sum over a speaker's claims) ideas-only | 1.19 [0.97, 1.42] | (reported) |
| bits/speaker (sum over a speaker's claims) +L4 | 5.98 [5.10, 6.91] | (reported) |
| C content composite | 0.83 | ≥ 0.8 |
| · T8 idea retention | 0.83 [0.80, 0.86] | |
| · T9 v3 public facts (no appendix) | 0.78 [0.72, 0.82] | |
| · T11 in-room QA | 0.87 [0.81, 0.92] | |
| (reported, not v5 hard zeros) T1 v4 (names / seats / bound private orgs) | 38 (26 / 11 / 1) | 0 |
| selfTraits (reported, not a hard zero in v4) | 16 | — |
| (reported) T2 v2 long quotes | 418 | 0 |
| T6 v3 outsider-named | 13 | 0 |
| +L4 claims / unattributable | 6888 / 232 (3.4%) | |
| aligner vs bigram agreement | 85.1% | |
| attacker parse failures (uniform fallback) | dashscope:qwen-plus: 150, dashscope:kimi-k3: 147 | |

Per attacker bits/claim:

| attacker | raw | ideas-only | +L4 |
|---|---|---|---|
| dashscope:qwen-plus | 2.11 [2.00, 2.21] | 0.81 [0.67, 0.95] | 0.82 [0.74, 0.90] |
| dashscope:kimi-k3 | 2.18 [2.07, 2.27] | 0.78 [0.66, 0.92] | 0.75 [0.67, 0.83] |

## v5 hard zeros (METHOD §10.4–§10.5)

| quantity | value | threshold |
|---|---|---|
| T1 v5 (private names / bound vocatives / private seats / bound orgs) | 34 (14 / 18 / 1 / 1) | 0 |
| · of which public persons' names in a bound position (reveal / mask miss) | 8 | |
| · of which attributable to a granted reveal | 1 | |
| T2 v5 sensitive long quotes | 5 | 0 |
| T2 plain long quotes (reported) | 418 | — |
| T6 v5 outsider-named (P10: public topic mentions are no evidence) | 3 | 0 |
| T6 v3 outsider-named (reported) | 13 | — |
| selfTraits (reported) | 16 | — |

## reveal_name (METHOD §10.2)

protocol: two-pass (requests ride the L3 JSON; code adjudicates; grants applied after every other layer)

| quantity | value |
|---|---|
| +L4 records with pseudonyms | 179 / 180 |
| requests (per record) | 73 (0.41) |
| granted (rate) | 20 (27.4%) |
| denied by reason | not-in-sentence 2, private 41, bound-position 10 |
| granted by kind (roster speakers / other persons) | 4 / 16 |
| token occurrences unmasked | 24 |
| granted persons re-masked in a bound / attributive position (post-check) | 3 |
| tokens in bound positions generalised | 73 |
| post-check re-masked names | 0 |
| persons tokenised (speakers / others / public, ASR variants) | 1057 / 1109 / 1369, 21 |

granted sentences (examples):

- the answer given was Tony and one other member
- It was resolved that Ashcraft, as mayor of the city of Alameda, proclaim [date] to 13, 2019 to be Alameda County Victims Rights Week, reaffirming the commitment to respect and enforce victims' rights and to address victims' needs during vic
- It was stated that the ordinance was sponsored by council members Steven Neal and [Person 1] in July 2012 and eventually adopted by City Council on August 6, 2013
- It was stated that the ordinance was sponsored by council members [Speaker 7] and Austin in July 2012 and eventually adopted by City Council on August 6, 2013
- Congratulations were extended to a council member, Neil, the staff and the community for bringing the initial ordinance to life and making it work (Regarding Development Services)
- The LGBTQ Center of Long Beach supports the proposed agenda item to annually recognise June as Pride Month in Long Beach, and gratitude was expressed to Pearce for leadership on the effort
- It was stated that Item 24 is communication from [Person 2] and Gonzalez, a role peers and council membership, and a recommendation to request that City of Long Beach annually recognise June as Pride Month
- Support for the proposed item was conveyed on behalf of a senator, together with recognition of Pearce for leadership on the effort
- Recognition was also given to the call authors Catwoman, Gonzalez, [Speaker 7] and Mr
- Recognition was also given to the call authors Catwoman, [Person 9], Pearce and Mr
- Agenda item number eight as well as agenda item number nine are two important projects in Austin's district
- The ayes carried and Herbert was given the floor


## Calibration ECE (10 bins, top-1)

{
 "dashscope:qwen-plus": {
  "raw": {
   "n": 1284,
   "before": {
    "ece": 0.028650311526488254,
    "n": 1284,
    "acc": 0.9158878504672897,
    "conf": 0.9160177570093584
   },
   "after": {
    "ece": 0.06957058814940124,
    "n": 1284,
    "acc": 0.9158878504672897,
    "conf": 0.8481345001164323
   }
  },
  "ideas-only": {
   "n": 1284,
   "before": {
    "ece": 0.2694233644859813,
    "n": 1284,
    "acc": 0.3886292834890966,
    "conf": 0.6580526479750805
   },
   "after": {
    "ece": 0.21088813409497006,
    "n": 1284,
    "acc": 0.3886292834890966,
    "conf": 0.5970361367227436
   }
  },
  "+L4": {
   "n": 6656,
   "before": {
    "ece": 0.2425713792067313,
    "n": 6656,
    "acc": 0.3856670673076923,
    "conf": 0.6277305138221034
   },
   "after": {
    "ece": 0.1865927483642796,
    "n": 6656,
    "acc": 0.3856670673076923,
    "conf": 0.5705133176392614
   }
  }
 },
 "dashscope:kimi-k3": {
  "raw": {
   "n": 1284,
   "before": {
    "ece": 0.05803130841121583,
    "n": 1284,
    "acc": 0.9400311526479751,
    "conf": 0.8838174454828716
   },
   "after": {
    "ece": 0.08446524488215224,
    "n": 1284,
    "acc": 0.9400311526479751,
    "conf": 0.8573831455643681
   }
  },
  "ideas-only": {
   "n": 1284,
   "before": {
    "ece": 0.0890264018691592,
    "n": 1284,
    "acc": 0.4190031152647975,
    "conf": 0.49091113707165174
   },
   "after": {
    "ece": 0.08119510289239562,
    "n": 1284,
    "acc": 0.4190031152647975,
    "conf": 0.47365002081308283
   }
  },
  "+L4": {
   "n": 6656,
   "before": {
    "ece": 0.03189860276442174,
    "n": 6656,
    "acc": 0.43419471153846156,
    "conf": 0.46548634314903836
   },
   "after": {
    "ece": 0.02099606897301732,
    "n": 6656,
    "acc": 0.43419471153846156,
    "conf": 0.44904008419298835
   }
  }
 }
}
`
