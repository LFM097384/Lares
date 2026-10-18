// L0 structural: drop speaker fields + timestamps, split into segments,
// cluster by topic (char-bigram / word Jaccard), shuffle with a seeded PRNG
// so turn order and per-speaker runs cannot be reconstructed.

export function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function shuffle(arr, rnd) {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(rnd() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; }
  return a;
}

export function splitSegments(text) {
  return String(text)
    .split(/(?<=[。！？!?；;])\s*|(?<!\b(?:Dr|Mr|Ms|Mrs|Prof|St|vs|etc|e\.g|i\.e|No))(?<=\.)\s+(?=[A-Z\u4e00-\u9fff"'“])/)
    .map((s) => s.trim())
    .filter((s) => s.replace(/[\s\p{P}]/gu, '').length >= 2);
}

const STOP = new Set('the a an and or of to in on for is are was were be it that this with as at by we i you they our my not but so if do does have has had can will would should could from there their them what which about just also than then very really like 的 了 是 在 我 我们 你 他 她 就 都 也 和 这 那 个 一 有 不 说'.split(' '));

export function features(s) {
  const f = new Set();
  const lower = s.toLowerCase();
  for (const w of lower.match(/[a-z][a-z0-9'-]{2,}/g) || []) if (!STOP.has(w)) f.add('w:' + w.replace(/(ing|ed|es|s)$/, ''));
  const cjk = lower.match(/[\u4e00-\u9fff]+/g) || [];
  for (const run of cjk) for (let i = 0; i + 1 < run.length; i++) { const bg = run.slice(i, i + 2); if (!STOP.has(bg[0]) || !STOP.has(bg[1])) f.add('c:' + bg); }
  for (const n of lower.match(/\d+(?:\.\d+)?%?/g) || []) if (n.length >= 2) f.add('n:' + n);
  return f;
}

function sim(a, b) {
  if (!a.size || !b.size) return 0;
  let inter = 0;
  for (const x of a) if (b.has(x)) inter++;
  return inter / Math.sqrt(a.size * b.size); // cosine-like on sets
}

export function structural(lines, { seed = 1, maxTopics = 6, threshold = 0.12 } = {}) {
  const segs = [];
  for (const l of lines || []) for (const s of splitSegments(l.text ?? l)) segs.push(s);
  const feats = segs.map(features);
  // Greedy single-pass clustering against cluster centroids (feature-count maps).
  const clusters = [];
  segs.forEach((s, i) => {
    let best = -1, bestSim = 0;
    clusters.forEach((c, k) => { const v = sim(feats[i], c.keys); if (v > bestSim) { bestSim = v; best = k; } });
    if (best >= 0 && (bestSim >= threshold || clusters.length >= maxTopics)) {
      const c = clusters[best]; c.idx.push(i); for (const x of feats[i]) { c.count.set(x, (c.count.get(x) || 0) + 1); c.keys.add(x); }
    } else {
      clusters.push({ idx: [i], keys: new Set(feats[i]), count: new Map([...feats[i]].map((x) => [x, 1])) });
    }
  });
  // Merge singleton clusters into nearest neighbour (singletons are ordering hints).
  for (let k = clusters.length - 1; k >= 0 && clusters.length > 1; k--) {
    if (clusters[k].idx.length > 1) continue;
    const i = clusters[k].idx[0];
    let best = -1, bestSim = -1;
    clusters.forEach((c, j) => { if (j !== k) { const v = sim(feats[i], c.keys); if (v > bestSim) { bestSim = v; best = j; } } });
    clusters[best].idx.push(i); for (const x of feats[i]) clusters[best].keys.add(x);
    clusters.splice(k, 1);
  }
  const rnd = mulberry32(seed);
  return shuffle(clusters, rnd).map((c, k) => ({ topic: `T${k + 1}`, segments: shuffle(c.idx.map((i) => segs[i]), rnd) }));
}
