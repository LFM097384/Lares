// EmberBench v4 · stranger bits-leakage estimator (METHOD §9.2–§9.3). Pure functions, no network.
import { rng } from '../bootstrap.mjs';

export const EPS = 0.02;
export const TAU_GRID = Array.from({ length: 201 }, (_, k) => Math.exp(Math.log(0.2) + (k / 200) * (Math.log(5) - Math.log(0.2))));

const norm = (s) => String(s ?? '').toLowerCase().normalize('NFKD').replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9\u3400-\u9fff]+/g, ' ').trim();

/**
 * Map one attacker answer for one claim onto the roster order. `p` may be {id: prob}, [{id|rosterId|speaker, p|prob|probability}],
 * keyed by roster id or by name / alias (case-insensitive). Percentages and unnormalised weights are fine; invalid keys are
 * dropped. Returns { p: number[] (sums to 1), ok } — all-zero / unparseable → uniform with ok=false.
 */
export function normaliseDist(p, roster) {
  const k = roster.length;
  const idx = new Map();
  roster.forEach((r, i) => { idx.set(String(r.id).toLowerCase(), i); for (const n of [r.name, ...(r.aliases || [])]) if (n && !idx.has(norm(n))) idx.set(norm(n), i); });
  const look = (key) => { const s = String(key ?? '').trim(); return idx.get(s.toLowerCase()) ?? idx.get(norm(s)); };
  const out = new Array(k).fill(0);
  let entries = [];
  if (Array.isArray(p)) entries = p.map((e) => [e?.id ?? e?.rosterId ?? e?.speaker ?? e?.name, e?.p ?? e?.prob ?? e?.probability ?? e?.confidence]);
  else if (p && typeof p === 'object') entries = Object.entries(p);
  for (const [key, v] of entries) {
    const i = look(key);
    let x = typeof v === 'string' ? parseFloat(v.replace('%', '')) : Number(v);
    if (i == null || !Number.isFinite(x) || x <= 0) continue;
    out[i] += x;
  }
  const s = out.reduce((a, b) => a + b, 0);
  if (!(s > 0)) return { p: new Array(k).fill(1 / k), ok: false };
  return { p: out.map((x) => x / s), ok: true };
}

/** Parse a whole attacker response: {claims:[{id, p}]} (also accepts {results|items|answers}). → Map claimId → raw p */
export function parseDistributions(json) {
  const rows = Array.isArray(json) ? json : json?.claims || json?.results || json?.items || json?.answers || [];
  const m = new Map();
  if (!Array.isArray(rows) && rows && typeof rows === 'object') { for (const [id, v] of Object.entries(rows)) m.set(String(id), v?.p ?? v?.probs ?? v); return m; }
  for (const r of rows) {
    const id = r?.id ?? r?.claimId ?? r?.claim ?? r?.i;
    if (id == null) continue;
    m.set(String(id), r?.p ?? r?.probs ?? r?.probabilities ?? r?.distribution ?? r?.dist ?? null);
  }
  return m;
}

export function smooth(p, eps = EPS) { const k = p.length; return p.map((x) => (1 - eps) * x + eps / k); }
export function applyTemp(p, tau = 1) {
  const q = p.map((x) => Math.pow(Math.max(x, 1e-12), 1 / tau));
  const s = q.reduce((a, b) => a + b, 0);
  return q.map((x) => x / s);
}
/** Per-claim leak: max(0, log2(p_true · k)). */
export function leakBits(pTrue, k) { return k > 1 ? Math.max(0, Math.log2(pTrue * k)) : 0; }

/** rows: [{p:number[] (normalised), t: trueIndex}] → { tau, nll, nll1, n } (grid search, smoothing applied first). */
export function fitTemperature(rows, { grid = TAU_GRID, eps = EPS } = {}) {
  const xs = rows.filter((r) => r && Array.isArray(r.p) && r.p.length > 1 && Number.isInteger(r.t) && r.t >= 0 && r.t < r.p.length).map((r) => ({ p: smooth(r.p, eps), t: r.t }));
  if (!xs.length) return { tau: 1, nll: null, nll1: null, n: 0 };
  const nll = (tau) => xs.reduce((s, r) => s - Math.log(applyTemp(r.p, tau)[r.t]), 0) / xs.length;
  let best = { tau: 1, nll: nll(1) };
  for (const tau of grid) { const v = nll(tau); if (v < best.nll - 1e-12) best = { tau, nll: v }; }
  return { tau: best.tau, nll: best.nll, nll1: nll(1), n: xs.length, atBoundary: best.tau === grid[0] || best.tau === grid[grid.length - 1] };
}

/** Expected calibration error on the top-1 probability, `bins` equal-width bins. rows: [{p, t}] (p already transformed). */
export function ece(rows, bins = 10) {
  const xs = rows.filter((r) => r && Array.isArray(r.p) && Number.isInteger(r.t));
  if (!xs.length) return { ece: null, n: 0, acc: null, conf: null };
  const B = Array.from({ length: bins }, () => ({ n: 0, c: 0, a: 0 }));
  let accAll = 0, confAll = 0;
  for (const r of xs) {
    let j = 0; for (let i = 1; i < r.p.length; i++) if (r.p[i] > r.p[j]) j = i;
    const conf = r.p[j], ok = j === r.t ? 1 : 0;
    const b = B[Math.min(bins - 1, Math.floor(conf * bins))];
    b.n++; b.c += conf; b.a += ok; accAll += ok; confAll += conf;
  }
  const e = B.reduce((s, b) => s + (b.n ? (b.n / xs.length) * Math.abs(b.a / b.n - b.c / b.n) : 0), 0);
  return { ece: e, n: xs.length, acc: accAll / xs.length, conf: confAll / xs.length };
}

/** Calibrated probability vector: smoothing then temperature. */
export const calibrate = (p, tau = 1, eps = EPS) => applyTemp(smooth(p, eps), tau);

// ---------------------------------------------------------------- claims

/** Bullet claims of a gate release: "- " lines outside the "Public record" appendix, header / review marks removed. */
export function extractClaims(release) {
  const out = [];
  let inRecord = false;
  for (const line of String(release ?? '').split(/\r?\n/)) {
    const h = line.match(/^#{1,6}\s*(.*)$/);
    if (h) { inRecord = /^(?:public record|公开记录)\b/i.test(h[1].trim()); continue; }
    if (inRecord) continue;
    const m = line.match(/^\s*[-*•]\s+(.*\S)\s*$/);
    if (!m) continue;
    const text = m[1].replace(/^\[review:[^\]]*\]\s*/i, '').trim();
    if (text.length >= 4) out.push(text);
  }
  return out;
}

const bigrams = (s) => { const w = norm(s).split(' ').filter((x) => x.length > 2); const b = new Set(); for (let i = 0; i + 1 < w.length; i++) b.add(`${w[i]} ${w[i + 1]}`); for (const x of w) if (x.length > 5) b.add(x); return b; };
/** Deterministic cross-check: roster id whose own lines share the most bigrams with the claim (null if no overlap). */
export function bigramSpeaker(claim, lines) {
  const cb = bigrams(claim);
  const score = new Map();
  for (const l of lines) { const lb = bigrams(l.text); let s = 0; for (const x of cb) if (lb.has(x)) s++; if (s) score.set(l.speakerId, (score.get(l.speakerId) || 0) + s); }
  let best = null, bs = 0; for (const [id, s] of score) if (s > bs) { best = id; bs = s; }
  return best;
}

// ---------------------------------------------------------------- hierarchical bootstrap

/**
 * units: [{ meeting, item, cells: { [config]: number[][] } }] where cells[config][a][j] = bits of claim j under attacker a
 * (each attacker's array aligned to the same claims). stat(sample) → number, where sample = [{meeting,item, mean:{[config]: maxOverAttackers(meanBits)}}].
 * Resamples meetings, then items within a meeting, then claims within each (item, config) — the same claim indices for every
 * attacker. Percentile CI.
 */
export function cellMean(cell, idx = null) {
  if (!cell || !cell.length) return null;
  let best = null;
  for (const arr of cell) {
    if (!arr || !arr.length) continue;
    const ix = idx || arr.map((_, j) => j);
    if (!ix.length) continue;
    const m = ix.reduce((s, j) => s + arr[j], 0) / ix.length;
    if (best == null || m > best) best = m;
  }
  return best;
}
export function itemMeans(units) { return units.map((u) => ({ meeting: u.meeting, item: u.item, mean: Object.fromEntries(Object.entries(u.cells).map(([c, cell]) => [c, cellMean(cell)])) })); }

export function hierBootstrap(units, stat, { B = 2000, seed = 12345, alpha = 0.05 } = {}) {
  const point = stat(itemMeans(units));
  const byM = new Map();
  for (const u of units) { if (!byM.has(u.meeting)) byM.set(u.meeting, []); byM.get(u.meeting).push(u); }
  const ms = [...byM.values()];
  const r = rng(seed);
  const pick = (n) => Math.floor(r() * n);
  const vals = [];
  for (let b = 0; b < B; b++) {
    const sample = [];
    for (let m = 0; m < ms.length; m++) {
      const mt = ms[pick(ms.length)];
      for (let i = 0; i < mt.length; i++) {
        const u = mt[pick(mt.length)];
        const mean = {};
        for (const [c, cell] of Object.entries(u.cells)) {
          const n = cell?.[0]?.length || 0;
          const idx = Array.from({ length: n }, () => pick(n));
          mean[c] = n ? cellMean(cell, idx) : null;
        }
        sample.push({ meeting: u.meeting, item: u.item, mean });
      }
    }
    const v = stat(sample);
    if (Number.isFinite(v)) vals.push(v);
  }
  vals.sort((x, y) => x - y);
  const q = (p) => { if (!vals.length) return null; const pos = (vals.length - 1) * p, lo = Math.floor(pos), hi = Math.ceil(pos); return vals[lo] + (vals[hi] - vals[lo]) * (pos - lo); };
  return { mean: Number.isFinite(point) ? point : null, lo: q(alpha / 2), hi: q(1 - alpha / 2), n: units.length, meetings: ms.length, B };
}

/** Mean of per-item config means (items lacking the config are skipped). */
export const meanOf = (config) => (s) => { const xs = s.map((x) => x.mean[config]).filter((v) => v != null); return xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : NaN; };
/** Paired excess: mean over items having both configs of (a − b). */
export const excessOf = (a, b) => (s) => { const xs = s.filter((x) => x.mean[a] != null && x.mean[b] != null).map((x) => x.mean[a] - x.mean[b]); return xs.length ? xs.reduce((p, q) => p + q, 0) / xs.length : NaN; };

// ---------------------------------------------------------------- memorisation-probe de-naming

const TITLE_WORDS = ['councilmember', 'councilmembers', 'council member', 'councilwoman', 'councilman', 'councillor', 'councilor', 'mayor', 'vice mayor', 'president', 'vice president', 'madam president', 'mr. president', 'chair', 'chairman', 'chairwoman', 'vice chair', 'clerk', 'secretary', 'commissioner', 'supervisor', 'alderman', 'madam chair', 'madam clerk', 'mr', 'mrs', 'ms', 'miss', 'dr'];
/** Deterministic de-naming for the memorisation probe (§9.7). */
export function deName(text, { names = [] } = {}) {
  let s = String(text ?? '');
  const toks = [...new Set(names.flatMap((n) => [n, ...String(n || '').split(/\s+/)]).map((x) => String(x || '').trim()).filter((x) => x.length >= 3 && !/^(?:speaker|participant|unnamed|the|and)$/i.test(x)))].sort((a, b) => b.length - a.length);
  for (const t of toks) s = s.replace(new RegExp(`\\b${t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'gi'), '[X]');
  s = s.replace(/\b(?:district|ward|seat|position)\s+(?:no\.?\s*)?(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|[A-Z])\b/gi, '[X]');
  for (const w of [...TITLE_WORDS].sort((a, b) => b.length - a.length)) s = s.replace(new RegExp(`\\b${w.replace(/\./g, '\\.')}\\b\\.?`, 'gi'), '[X]');
  return s.replace(/(?:\[X\]\s*){2,}/g, '[X] ');
}
