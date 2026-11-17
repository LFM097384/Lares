# EmberBench v4 rescore — 2026-11-07T1730-public-dev (s1)

version emberbench-4 · attackers dashscope:qwen-plus, dashscope:kimi-k3 · calibration τ dashscope:qwen-plus=1.233, dashscope:kimi-k3=1.049
split dev · 18 items · records 162 · datasetHash 30092028f3d0… · no gate calls

**Overall: FAIL** (hard zeros PASS · P1 PASS · C FAIL · raw sanity ok)

| quantity | value [95% CI] | threshold |
|---|---|---|
| P1 excess bits/claim (+L4 − ideas-only, max over attackers) | 0.01 [-0.19, 0.19] | CI upper ≤ 0.25 |
| P1, unattributable claims counted as 0 bits | 0.00 [-0.20, 0.18] | (sensitivity) |
| P1, any-source truth | 0.07 [-0.14, 0.26] | (sensitivity) |
| bits/claim raw | 2.36 [2.12, 2.63] | mean ≥ 1 (sanity) |
| bits/claim ideas-only | 1.05 [0.79, 1.37] |  |
| bits/claim +L4 | 1.07 [0.85, 1.30] |  |
| raw − ideas-only | 1.30 [1.04, 1.54] | |
| bits/speaker (sum over a speaker's claims) raw | 2.14 [1.59, 2.75] | (reported) |
| bits/speaker (sum over a speaker's claims) ideas-only | 1.04 [0.69, 1.41] | (reported) |
| bits/speaker (sum over a speaker's claims) +L4 | 5.86 [4.27, 7.62] | (reported) |
| C content composite | 0.77 | ≥ 0.8 |
| · T8 idea retention | 0.80 [0.75, 0.85] | |
| · T9 v3 public facts (no appendix) | 0.70 [0.59, 0.79] | |
| · T11 in-room QA | 0.80 [0.68, 0.90] | |
| T1 v4 (names / seats / bound private orgs) | 0 (0 / 0 / 0) | 0 |
| selfTraits (reported, not a hard zero in v4) | 0 | — |
| T2 long quotes | 0 | 0 |
| T6 v3 outsider-named | 0 | 0 |
| +L4 claims / unattributable | 2146 / 31 (1.4%) | |
| aligner vs bigram agreement | 84.3% | |
| attacker parse failures (uniform fallback) | dashscope:qwen-plus: 1, dashscope:kimi-k3: 0 | |

Per attacker bits/claim:

| attacker | raw | ideas-only | +L4 |
|---|---|---|---|
| dashscope:qwen-plus | 2.21 [1.93, 2.49] | 0.99 [0.71, 1.30] | 1.03 [0.85, 1.23] |
| dashscope:kimi-k3 | 2.33 [2.06, 2.60] | 0.96 [0.68, 1.24] | 0.95 [0.74, 1.18] |

Memorisation probe (18 items): bits/excerpt 1.52 [1.26, 1.84], excess over ideas-only 0.46 [0.12, 0.84], meeting (year+month) hit rate 6% (dashscope:qwen-plus 1, dashscope:kimi-k3 1) → no memorisation flag

## Calibration ECE (10 bins, top-1)

```
{
 "dashscope:qwen-plus": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.07068142076502643,
    "n": 366,
    "acc": 0.8524590163934426,
    "conf": 0.910572131147541
   },
   "after": {
    "ece": 0.04756959450385643,
    "n": 366,
    "acc": 0.8524590163934426,
    "conf": 0.8386998968130913
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.2415633879781421,
    "n": 366,
    "acc": 0.4016393442622951,
    "conf": 0.6432027322404363
   },
   "after": {
    "ece": 0.1853055869182893,
    "n": 366,
    "acc": 0.4016393442622951,
    "conf": 0.5809567445316933
   }
  },
  "+L4": {
   "n": 2115,
   "before": {
    "ece": 0.21157125295508228,
    "n": 2115,
    "acc": 0.43120567375886526,
    "conf": 0.6427769267139493
   },
   "after": {
    "ece": 0.15037716681303215,
    "n": 2115,
    "acc": 0.43120567375886526,
    "conf": 0.5815828405718952
   }
  }
 },
 "dashscope:kimi-k3": {
  "raw": {
   "n": 366,
   "before": {
    "ece": 0.06071038251366119,
    "n": 366,
    "acc": 0.8770491803278688,
    "conf": 0.8796174863387961
   },
   "after": {
    "ece": 0.06986956567617911,
    "n": 366,
    "acc": 0.8770491803278688,
    "conf": 0.8532662261869622
   }
  },
  "ideas-only": {
   "n": 366,
   "before": {
    "ece": 0.07295546448087434,
    "n": 366,
    "acc": 0.45901639344262296,
    "conf": 0.48557841530054596
   },
   "after": {
    "ece": 0.05926612060478944,
    "n": 366,
    "acc": 0.45901639344262296,
    "conf": 0.4671168799033524
   }
  },
  "+L4": {
   "n": 2115,
   "before": {
    "ece": 0.05959834515366461,
    "n": 2115,
    "acc": 0.484160756501182,
    "conf": 0.46615030732860263
   },
   "after": {
    "ece": 0.05423501780394318,
    "n": 2115,
    "acc": 0.484160756501182,
    "conf": 0.44939745922130997
   }
  }
 }
}
```
