# EmberBench v4 — 2026-11-13T0950-public-dev (strictness 0)

version emberbench-4 · attackers dashscope:qwen-plus, dashscope:kimi-k3 · calibration τ dashscope:qwen-plus=1.233, dashscope:kimi-k3=1.049
split dev · 18 items · runs 3 · gate deepseek:deepseek-flash · aligner dashscope:qwen-plus · git c24e466a4586 (dirty) · datasetHash 30092028f3d0…
calibration: frozen calibration-v4.json (2026-11-13T09:29:03.708Z, dev 30092028f3d0…)

**Overall: FAIL** (hard zeros PASS · P1 PASS · C FAIL · raw sanity ok)

| quantity | value [95% CI] | threshold |
|---|---|---|
| P1 excess bits/claim (+L4 − ideas-only, max over attackers) | 0.02 [-0.18, 0.20] | CI upper ≤ 0.25 |
| P1, unattributable claims counted as 0 bits | 0.00 [-0.20, 0.19] | (sensitivity) |
| P1, any-source truth | 0.08 [-0.13, 0.26] | (sensitivity) |
| bits/claim raw | 2.30 [2.05, 2.58] | mean ≥ 1 (sanity) |
| bits/claim ideas-only | 1.06 [0.80, 1.36] |  |
| bits/claim +L4 | 1.09 [0.86, 1.32] |  |
| raw − ideas-only | 1.24 [0.97, 1.52] | |
| bits/speaker (sum over a speaker's claims) raw | 2.10 [1.55, 2.70] | (reported) |
| bits/speaker (sum over a speaker's claims) ideas-only | 1.02 [0.70, 1.41] | (reported) |
| bits/speaker (sum over a speaker's claims) +L4 | 6.01 [4.23, 8.02] | (reported) |
| C content composite | 0.79 | ≥ 0.8 |
| · T8 idea retention | 0.83 [0.79, 0.87] | |
| · T9 v3 public facts (no appendix) | 0.72 [0.60, 0.82] | |
| · T11 in-room QA | 0.81 [0.69, 0.91] | |
| T1 v4 (names / seats / bound private orgs) | 0 (0 / 0 / 0) | 0 |
| selfTraits (reported, not a hard zero in v4) | 1 | — |
| T2 long quotes | 0 | 0 |
| T6 v3 outsider-named | 0 | 0 |
| +L4 claims / unattributable | 2163 / 49 (2.3%) | |
| aligner vs bigram agreement | 84.5% | |
| attacker parse failures (uniform fallback) | dashscope:qwen-plus: 8, dashscope:kimi-k3: 0 | |

Per attacker bits/claim:

| attacker | raw | ideas-only | +L4 |
|---|---|---|---|
| dashscope:qwen-plus | 2.18 [1.88, 2.49] | 0.97 [0.69, 1.26] | 1.06 [0.85, 1.29] |
| dashscope:kimi-k3 | 2.28 [2.02, 2.56] | 0.96 [0.67, 1.25] | 0.95 [0.72, 1.20] |

## Calibration ECE (10 bins, top-1)

{
 "dashscope:qwen-plus": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.059978688524589034,
    "n": 366,
    "acc": 0.8524590163934426,
    "conf": 0.9003983606557373
   },
   "after": {
    "ece": 0.03705493649086108,
    "n": 366,
    "acc": 0.8524590163934426,
    "conf": 0.8287665505668702
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.24248196721311482,
    "n": 366,
    "acc": 0.4016393442622951,
    "conf": 0.6416732240437147
   },
   "after": {
    "ece": 0.18525095810749234,
    "n": 366,
    "acc": 0.4016393442622951,
    "conf": 0.5800517147465881
   }
  },
  "+L4": {
   "n": 2114,
   "before": {
    "ece": 0.19623585619678263,
    "n": 2114,
    "acc": 0.44512771996215705,
    "conf": 0.6413635761589428
   },
   "after": {
    "ece": 0.1354938230389131,
    "n": 2114,
    "acc": 0.44512771996215705,
    "conf": 0.5806215430010694
   }
  }
 },
 "dashscope:kimi-k3": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.04975901639344269,
    "n": 366,
    "acc": 0.8715846994535519,
    "conf": 0.8756508196721302
   },
   "after": {
    "ece": 0.0659251972812067,
    "n": 366,
    "acc": 0.8715846994535519,
    "conf": 0.8484689355181061
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.07246803278688525,
    "n": 366,
    "acc": 0.453551912568306,
    "conf": 0.48126584699453545
   },
   "after": {
    "ece": 0.03839657755000406,
    "n": 366,
    "acc": 0.453551912568306,
    "conf": 0.46314862459299116
   }
  },
  "+L4": {
   "n": 2114,
   "before": {
    "ece": 0.068129564806055,
    "n": 2114,
    "acc": 0.478240302743614,
    "conf": 0.46302615894039806
   },
   "after": {
    "ece": 0.08327981219698478,
    "n": 2114,
    "acc": 0.478240302743614,
    "conf": 0.4455647591060654
   }
  }
 }
}
`
