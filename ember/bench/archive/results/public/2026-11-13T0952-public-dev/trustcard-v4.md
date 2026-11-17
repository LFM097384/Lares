# EmberBench v4 — 2026-11-13T0952-public-dev (strictness 2)

version emberbench-4 · attackers dashscope:qwen-plus, dashscope:kimi-k3 · calibration τ dashscope:qwen-plus=1.233, dashscope:kimi-k3=1.049
split dev · 18 items · runs 3 · gate deepseek:deepseek-flash · aligner dashscope:qwen-plus · git c24e466a4586 (dirty) · datasetHash 30092028f3d0…
calibration: frozen calibration-v4.json (2026-11-13T09:29:03.708Z, dev 30092028f3d0…)

**Overall: FAIL** (hard zeros FAIL · P1 PASS · C FAIL · raw sanity ok)

| quantity | value [95% CI] | threshold |
|---|---|---|
| P1 excess bits/claim (+L4 − ideas-only, max over attackers) | 0.02 [-0.20, 0.25] | CI upper ≤ 0.25 |
| P1, unattributable claims counted as 0 bits | 0.00 [-0.22, 0.23] | (sensitivity) |
| P1, any-source truth | 0.07 [-0.15, 0.31] | (sensitivity) |
| bits/claim raw | 2.35 [2.09, 2.61] | mean ≥ 1 (sanity) |
| bits/claim ideas-only | 1.06 [0.77, 1.36] |  |
| bits/claim +L4 | 1.08 [0.84, 1.32] |  |
| raw − ideas-only | 1.29 [1.01, 1.57] | |
| bits/speaker (sum over a speaker's claims) raw | 2.12 [1.56, 2.72] | (reported) |
| bits/speaker (sum over a speaker's claims) ideas-only | 1.04 [0.72, 1.43] | (reported) |
| bits/speaker (sum over a speaker's claims) +L4 | 6.26 [4.49, 8.28] | (reported) |
| C content composite | 0.79 | ≥ 0.8 |
| · T8 idea retention | 0.82 [0.78, 0.86] | |
| · T9 v3 public facts (no appendix) | 0.74 [0.64, 0.82] | |
| · T11 in-room QA | 0.80 [0.69, 0.90] | |
| T1 v4 (names / seats / bound private orgs) | 2 (1 / 0 / 1) | 0 |
| selfTraits (reported, not a hard zero in v4) | 0 | — |
| T2 long quotes | 0 | 0 |
| T6 v3 outsider-named | 0 | 0 |
| +L4 claims / unattributable | 2261 / 44 (1.9%) | |
| aligner vs bigram agreement | 83.7% | |
| attacker parse failures (uniform fallback) | dashscope:qwen-plus: 2, dashscope:kimi-k3: 0 | |

Per attacker bits/claim:

| attacker | raw | ideas-only | +L4 |
|---|---|---|---|
| dashscope:qwen-plus | 2.24 [1.97, 2.53] | 0.96 [0.66, 1.24] | 1.03 [0.82, 1.25] |
| dashscope:kimi-k3 | 2.29 [2.00, 2.60] | 0.97 [0.66, 1.28] | 0.98 [0.72, 1.24] |

## Calibration ECE (10 bins, top-1)

{
 "dashscope:qwen-plus": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.05937158469945267,
    "n": 366,
    "acc": 0.8688524590163934,
    "conf": 0.9081693989071038
   },
   "after": {
    "ece": 0.05050999604807837,
    "n": 366,
    "acc": 0.8688524590163934,
    "conf": 0.8358138275180013
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.2659833333333333,
    "n": 366,
    "acc": 0.3743169398907104,
    "conf": 0.6403002732240429
   },
   "after": {
    "ece": 0.2066650924833287,
    "n": 366,
    "acc": 0.3743169398907104,
    "conf": 0.5773422838688766
   }
  },
  "+L4": {
   "n": 2217,
   "before": {
    "ece": 0.22003013080739683,
    "n": 2217,
    "acc": 0.41858367162832655,
    "conf": 0.6386138024357275
   },
   "after": {
    "ece": 0.16048041954148173,
    "n": 2217,
    "acc": 0.41858367162832655,
    "conf": 0.5790640911698055
   }
  }
 },
 "dashscope:kimi-k3": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.034863387978141695,
    "n": 366,
    "acc": 0.8770491803278688,
    "conf": 0.8884153005464477
   },
   "after": {
    "ece": 0.05794389077917763,
    "n": 366,
    "acc": 0.8770491803278688,
    "conf": 0.8618076982676754
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.05784153005464474,
    "n": 366,
    "acc": 0.45901639344262296,
    "conf": 0.4922131147540981
   },
   "after": {
    "ece": 0.04485683806150577,
    "n": 366,
    "acc": 0.45901639344262296,
    "conf": 0.4734872393154848
   }
  },
  "+L4": {
   "n": 2217,
   "before": {
    "ece": 0.059524357239512736,
    "n": 2217,
    "acc": 0.487595850248083,
    "conf": 0.4597228236355441
   },
   "after": {
    "ece": 0.06839102993872392,
    "n": 2217,
    "acc": 0.487595850248083,
    "conf": 0.44261730246453246
   }
  }
 }
}
`
