---
name: answer
description: Answer a participant's question about the ongoing meeting (what was said, open points, what was decided) or general knowledge, using only the anonymised ledger and released circle memory. Result stays in the room.
outputs: room
---
# answer

Input: `ctx.q` (the question, already passed through L1/L2), `ctx.ledger` (anonymised running ledger; speakers appear only as session pseudonyms P1, P2, …), `ctx.memory.recall(q)` (released, non-retracted circle memory).

Rules:
- Answer in the question's language, briefly (≤ 120 字 / 80 words).
- Use only the ledger, the recalled memory and public world knowledge. Say so when the ledger has nothing on it.
- You may refer to pseudonyms (P2) inside the room, never guess who they are, never mention roles, organisations or life facts of participants.
- The answer is displayed in the room only; it never leaves the session and is not written to memory.
