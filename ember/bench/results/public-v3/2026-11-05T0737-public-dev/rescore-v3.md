# EmberBench v3 rescore — 2026-11-05T0737-public-dev

Records: 162 (dev); v3 gold: data/dev gold.spansV3 (datasetHash 30092028f3d0…); no gate / attacker calls (METHOD §8.7).
v2 deterministic leak counts reproduced from stored text: yes

| config | T1 v2 | T1 v3 (names / roles / orgs / selfTraits) | T6 v2 | T6 v3 (unpaired) | T9 v2 (no appendix) | T9 v3 (no appendix) | T9b | T12 v2 | T12 v3 | topic retention |
|---|---|---|---|---|---|---|---|---|---|---|
| +L4 | 31 | 4 (2 / 0 / 2 / 0) | 25 | 1 (1) | 0.63 (0.61) | 0.74 [0.62, 0.83] | 0.99 [0.98, 1.00] 147/148 | 0.14 | 0.03 [0.00, 0.09] | 0.87 [0.72, 1.00] |
| raw | 366 | 303 (189 / 96 / 15 / 3) | 186 | 138 (139) | 1 (1) | 1.00 [1.00, 1.00] | 1.00 [1.00, 1.00] 168/168 | 0.93 | 0.98 [0.93, 1.00] | 1.00 [1.00, 1.00] |
| ideas-only | — | 0 (0 / 0 / 0 / 0) | 6 | — (0) | — (—) | 0.20 [0.12, 0.27] | 1.00 [1.00, 1.00] 30/30 | — | 0.02 [0.00, 0.09] | 0.40 [0.18, 0.63] |

+L4 v3 verdicts: T1 FAIL · T6 FAIL · T9 FAIL · T9b PASS · T12 PASS
+L4 v2 verdicts: T1 FAIL · T2 FAIL · T3 N/A · T4 PASS · T5 FAIL · T6 FAIL · T7 PASS · T8 FAIL · T9 FAIL · T10 PASS · T11 FAIL · T12 FAIL

ideas-only text = the gold idea list; its T6 is the unpaired control (pairing against itself is 0 by construction).
