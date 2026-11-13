// Gate strictness knob (EmberBench v4, METHOD §9.8). Public-body mode only; outside it every level is the default path.
// 1 = default (current behaviour, unchanged code path). 0 = lenient (less generalisation), 2–3 = stricter.
export const STRICTNESS_LEVELS = [0, 1, 2, 3];
export const DEFAULT_STRICTNESS = 1;
export function strictnessProfile(level, { threshold = 0.5, maxRounds = 2 } = {}) {
  const n = Number(level);
  const s = Number.isInteger(n) && n >= 0 && n <= 3 ? n : DEFAULT_STRICTNESS;
  const base = { level: s, stripSelfTraits: true, threshold, maxRounds, fixAll: false, withholdAll: false, strictNote: false };
  if (s === 0) return { ...base, stripSelfTraits: false, threshold: Math.max(threshold, 0.7), maxRounds: Math.min(maxRounds, 1) };
  if (s === 2) return { ...base, threshold: Math.min(threshold, 0.4), maxRounds: Math.max(maxRounds, 3), fixAll: true };
  if (s === 3) return { ...base, threshold: Math.min(threshold, 0.3), maxRounds: Math.max(maxRounds, 3), fixAll: true, withholdAll: true, strictNote: true };
  return base;
}
