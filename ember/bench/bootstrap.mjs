// EmberBench · seeded bootstrap CIs and run-spread summaries (pure).

/** mulberry32 PRNG → () => [0,1) */
export function rng(seed = 1) {
  let a = (Number(seed) >>> 0) || 1;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const mean = (xs) => (xs.length ? xs.reduce((s, x) => s + x, 0) / xs.length : NaN);
function quantile(sorted, q) {
  if (!sorted.length) return NaN;
  const pos = (sorted.length - 1) * q;
  const lo = Math.floor(pos), hi = Math.ceil(pos);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
}

/** Percentile bootstrap of the mean over units (e.g. transcripts). values: number[] (NaN/null dropped). */
export function bootstrapMean(values, { B = 2000, seed = 12345, alpha = 0.05 } = {}) {
  const xs = values.filter((v) => typeof v === 'number' && Number.isFinite(v));
  const n = xs.length;
  if (!n) return { mean: null, lo: null, hi: null, n: 0 };
  const r = rng(seed);
  const ms = new Array(B);
  for (let b = 0; b < B; b++) {
    let s = 0;
    for (let i = 0; i < n; i++) s += xs[Math.floor(r() * n)];
    ms[b] = s / n;
  }
  ms.sort((a, b) => a - b);
  return { mean: mean(xs), lo: quantile(ms, alpha / 2), hi: quantile(ms, 1 - alpha / 2), n };
}

/** Ratio-of-sums bootstrap (numerator/denominator per unit, e.g. leaked/total identifiers per transcript). */
export function bootstrapRatio(pairs, { B = 2000, seed = 12345, alpha = 0.05 } = {}) {
  const xs = pairs.filter((p) => p && Number.isFinite(p[0]) && Number.isFinite(p[1]));
  const n = xs.length;
  const tot = xs.reduce((s, [, d]) => s + d, 0);
  if (!n || !tot) return { mean: null, lo: null, hi: null, n };
  const point = xs.reduce((s, [a]) => s + a, 0) / tot;
  const r = rng(seed);
  const ms = [];
  for (let b = 0; b < B; b++) {
    let a = 0, d = 0;
    for (let i = 0; i < n; i++) { const p = xs[Math.floor(r() * n)]; a += p[0]; d += p[1]; }
    if (d) ms.push(a / d);
  }
  ms.sort((x, y) => x - y);
  return { mean: point, lo: quantile(ms, alpha / 2), hi: quantile(ms, 1 - alpha / 2), n };
}

/** Spread of per-run dataset means: {runs, means, sd, min, max}. */
export function spread(runMeans) {
  const xs = runMeans.filter((v) => Number.isFinite(v));
  if (!xs.length) return { runs: 0, means: [], sd: null, min: null, max: null };
  const m = mean(xs);
  const sd = xs.length > 1 ? Math.sqrt(xs.reduce((s, x) => s + (x - m) ** 2, 0) / (xs.length - 1)) : 0;
  return { runs: xs.length, means: xs, sd, min: Math.min(...xs), max: Math.max(...xs) };
}

export { mean };
