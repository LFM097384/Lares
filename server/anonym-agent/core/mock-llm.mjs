// Test / offline LLM doubles matching the injected-LLM contract (IMPL-NOTES "Injected LLM"):
//   llm = { async chat(messages, { json, temperature, maxTokens }) -> { text, usage, finish } }
// NOTE: production code paths treat `llm == null` as "deterministic mock" (gate mock L3/L4, mock
// ask answers, mock generalise). These doubles exist for tests that need to observe prompts or
// script replies through the real LLM code paths.

// createScriptedLLM(handler): handler(messages, opts, callIndex) -> string | object | Promise thereof.
// Objects are JSON-stringified. Every call is recorded in llm.calls (test-side only).
export function createScriptedLLM(handler) {
  const calls = [];
  return {
    calls,
    async chat(messages, opts = {}) {
      const idx = calls.length;
      calls.push({ messages, opts });
      let out = await handler(messages, opts, idx);
      if (out && typeof out === 'object') out = JSON.stringify(out);
      const text = String(out ?? '');
      return { text, usage: { prompt_tokens: 0, completion_tokens: 0 }, finish: 'stop' };
    },
  };
}

const userText = (messages) => messages.filter((m) => m.role === 'user').map((m) => String(m.content)).join('\n');
const sysText = (messages) => messages.filter((m) => m.role === 'system').map((m) => String(m.content)).join('\n');

// A crude default that returns *valid JSON* for the gate prompts so code paths run end to end:
//  - L3 rewrite ("FRAGMENTS:")         -> {"sections":[{topic, claims: fragments verbatim}]}
//  - L4 attacker ("red-team")          -> {"results":[]}            (nobody attributable)
//  - L4 generaliser ("FLAGGED CLAIMS") -> {"rewrites":[]}           (fail closed: DROP)
//  - anything else                     -> plain text echo of the last user line
// It is NOT a de-identifier; it does not paraphrase. Use only in tests.
export function defaultMockHandler(messages) {
  const sys = sysText(messages), user = userText(messages);
  if (/red-team/i.test(sys)) return { results: [] };
  if (/FLAGGED CLAIMS/.test(user)) return { rewrites: [] };
  if (/FRAGMENTS:/.test(user)) {
    const sections = [];
    for (const block of user.split(/\n(?=## Cluster )/)) {
      const m = block.match(/^## Cluster \d+: (.*)$/m);
      if (!m) continue;
      const claims = [...block.matchAll(/^- (.+)$/gm)].map((x) => x[1].trim()).filter(Boolean);
      if (claims.length) sections.push({ topic: m[1].trim(), claims });
    }
    return { sections };
  }
  const lines = user.trim().split('\n');
  return lines[lines.length - 1] || '';
}

export const createMockLLM = () => createScriptedLLM(defaultMockHandler);
