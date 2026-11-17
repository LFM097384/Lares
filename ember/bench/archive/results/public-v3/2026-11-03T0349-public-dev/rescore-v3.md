# EmberBench v3 rescore — 2026-11-03T0349-public-dev

Records: 162 (dev); v3 gold: data/dev gold.spansV3 (datasetHash 30092028f3d0…); no gate / attacker calls (METHOD §8.7).
v2 deterministic leak counts reproduced from stored text: yes

| config | T1 v2 | T1 v3 (names / roles / orgs / selfTraits) | T6 v2 | T6 v3 (unpaired) | T9 v2 (no appendix) | T9 v3 (no appendix) | T9b | T12 v2 | T12 v3 | topic retention |
|---|---|---|---|---|---|---|---|---|---|---|
| +L4 | 1 | 3 (0 / 0 / 0 / 3) | 3 | 0 (0) | 0.54 (0.48) | 0.63 [0.50, 0.73] | 0.97 [0.94, 1.00] 111/114 | 0.10 | 0.06 [0.00, 0.19] | 0.42 [0.17, 0.65] |
| raw | 366 | 303 (189 / 96 / 15 / 3) | 182 | 139 (139) | 1 (1) | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] 168/168 | 0.93 | 0.98 [0.93, 1.00] | 1.00 [1.00, 1.00] |
| ideas-only | — | 0 (0 / 0 / 0 / 0) | 6 | — (0) | — (—) | 0.20 [0.13, 0.27] | 1.00 [1.00, 1.00] 30/30 | — | 0.02 [0.00, 0.09] | 0.40 [0.18, 0.63] |

+L4 v3 verdicts: T1 FAIL · T6 PASS · T9 FAIL · T9b PASS · T12 PASS
+L4 v2 verdicts: T1 FAIL · T2 PASS · T3 N/A · T4 PASS · T5 PASS · T6 FAIL · T7 FAIL · T8 FAIL · T9 FAIL · T10 PASS · T11 PASS · T12 PASS

ideas-only text = the gold idea list; its T6 is the unpaired control (pairing against itself is 0 by construction).
