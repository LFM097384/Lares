---
name: minutes
description: Produce exportable meeting minutes (topics, ideas, decisions, to-dos, public facts) with no speakers. Goes through draft → review → k-of-n signed release; the released markdown is written to circle memory.
outputs: release
---
# minutes

Input: `ctx.ledger` only (anonymised; pseudonyms P1, P2, … are stripped from every item before the draft is built).

Output: `{ items: [{ topic, kind: idea|decision|todo|fact, text, flags? }] }` — one claim per item.

Rules:
- No speakers, no pseudonyms, no "someone said" attribution: impersonal phrasing ("有观点认为……", "It was agreed that …").
- Group by topic (2–6 words, no people). Keep numbers, decisions and to-dos; to-dos have no owner.
- Keep public world facts verbatim (a well-known book and its author, laws, public reports) as `kind: fact`, flag `public-fact`.
- Sarcasm / irony already neutralised in the ledger must stay neutral; never re-quote it.
- The agent then runs L4 (roster-token scan + role/self-reveal check) and marks risky items `roleRisk`; those are released only after a participant keeps or generalises them.
