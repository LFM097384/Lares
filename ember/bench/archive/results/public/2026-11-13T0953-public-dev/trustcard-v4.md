# EmberBench v4 — 2026-11-13T0953-public-dev (strictness 3)

version emberbench-4 · attackers dashscope:qwen-plus, dashscope:kimi-k3 · calibration τ dashscope:qwen-plus=1.233, dashscope:kimi-k3=1.049
split dev · 18 items · runs 3 · gate deepseek:deepseek-flash · aligner dashscope:qwen-plus · git c24e466a4586 (dirty) · datasetHash 30092028f3d0…
calibration: frozen calibration-v4.json (2026-11-13T09:29:03.708Z, dev 30092028f3d0…)

**Overall: FAIL** (hard zeros FAIL · P1 PASS · C FAIL · raw sanity ok)

| quantity | value [95% CI] | threshold |
|---|---|---|
| P1 excess bits/claim (+L4 − ideas-only, max over attackers) | -0.01 [-0.19, 0.16] | CI upper ≤ 0.25 |
| P1, unattributable claims counted as 0 bits | -0.02 [-0.21, 0.15] | (sensitivity) |
| P1, any-source truth | 0.05 [-0.15, 0.22] | (sensitivity) |
| bits/claim raw | 2.32 [2.07, 2.60] | mean ≥ 1 (sanity) |
| bits/claim ideas-only | 1.05 [0.79, 1.34] |  |
| bits/claim +L4 | 1.04 [0.83, 1.26] |  |
| raw − ideas-only | 1.27 [0.99, 1.53] | |
| bits/speaker (sum over a speaker's claims) raw | 2.09 [1.53, 2.69] | (reported) |
| bits/speaker (sum over a speaker's claims) ideas-only | 1.04 [0.71, 1.42] | (reported) |
| bits/speaker (sum over a speaker's claims) +L4 | 5.84 [4.23, 7.64] | (reported) |
| C content composite | 0.76 | ≥ 0.8 |
| · T8 idea retention | 0.79 [0.76, 0.83] | |
| · T9 v3 public facts (no appendix) | 0.71 [0.59, 0.80] | |
| · T11 in-room QA | 0.79 [0.68, 0.89] | |
| T1 v4 (names / seats / bound private orgs) | 1 (0 / 0 / 1) | 0 |
| selfTraits (reported, not a hard zero in v4) | 0 | — |
| T2 long quotes | 0 | 0 |
| T6 v3 outsider-named | 0 | 0 |
| +L4 claims / unattributable | 2157 / 38 (1.8%) | |
| aligner vs bigram agreement | 83.7% | |
| attacker parse failures (uniform fallback) | dashscope:qwen-plus: 4, dashscope:kimi-k3: 0 | |

Per attacker bits/claim:

| attacker | raw | ideas-only | +L4 |
|---|---|---|---|
| dashscope:qwen-plus | 2.19 [1.89, 2.50] | 0.99 [0.70, 1.27] | 1.02 [0.81, 1.25] |
| dashscope:kimi-k3 | 2.30 [2.02, 2.61] | 0.97 [0.69, 1.26] | 0.92 [0.67, 1.17] |

## Calibration ECE (10 bins, top-1)

{
 "dashscope:qwen-plus": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.06526202185792235,
    "n": 366,
    "acc": 0.8579234972677595,
    "conf": 0.9106718579234973
   },
   "after": {
    "ece": 0.03211578105032361,
    "n": 366,
    "acc": 0.8579234972677595,
    "conf": 0.8384448247737111
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.23979808743169395,
    "n": 366,
    "acc": 0.3989071038251366,
    "conf": 0.6387051912568298
   },
   "after": {
    "ece": 0.1784470120590328,
    "n": 366,
    "acc": 0.3989071038251366,
    "conf": 0.5766745245123075
   }
  },
  "+L4": {
   "n": 2119,
   "before": {
    "ece": 0.21835563945257117,
    "n": 2119,
    "acc": 0.42189712128362433,
    "conf": 0.6394348277489407
   },
   "after": {
    "ece": 0.15878435391715587,
    "n": 2119,
    "acc": 0.42189712128362433,
    "conf": 0.579863479290759
   }
  }
 },
 "dashscope:kimi-k3": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.03939890710382508,
    "n": 366,
    "acc": 0.8825136612021858,
    "conf": 0.8924043715846979
   },
   "after": {
    "ece": 0.03426685213118855,
    "n": 366,
    "acc": 0.8825136612021858,
    "conf": 0.8659823529701639
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.06144808743169394,
    "n": 366,
    "acc": 0.43169398907103823,
    "conf": 0.48920765027322377
   },
   "after": {
    "ece": 0.05680411670155167,
    "n": 366,
    "acc": 0.43169398907103823,
    "conf": 0.4712658138149046
   }
  },
  "+L4": {
   "n": 2119,
   "before": {
    "ece": 0.04698914582350178,
    "n": 2119,
    "acc": 0.4709768758848513,
    "conf": 0.45487022180273745
   },
   "after": {
    "ece": 0.05787421266807283,
    "n": 2119,
    "acc": 0.4709768758848513,
    "conf": 0.43810459014322267
   }
  }
 }
}
`
