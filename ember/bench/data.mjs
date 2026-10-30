// EmberBench · dataset loading, split integrity, hash pinning and the test seal.
//   data/<split>/*.json          transcripts (bench schema; *.check.json / *.rejected.json are review artefacts)
//   data/test.manifest.json      {version, files:{name: sha256}, datasetHash}   — test is frozen by this
//   data/test.seal.json          written after the one pre-tuning test run; later test runs need --break-seal
import { readFileSync, readdirSync, existsSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

export const DATA_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), 'data');
// EmberBench-Public (METHOD §7): transcripts are real council text → kept out of git under .data/; only the hash-only
// manifest / seal / selection list live in the repo (data/public/).
export const PUBLIC_DATA_DIR = path.resolve(DATA_DIR, '..', '..', '..', '.data', 'emberbench-public', 'data');
export const PUBLIC_META_DIR = path.join(DATA_DIR, 'public');
export const TRACKS = {
  synthetic: { data: DATA_DIR, meta: DATA_DIR },
  public: { data: PUBLIC_DATA_DIR, meta: PUBLIC_META_DIR },
};
const sha = (buf) => createHash('sha256').update(buf).digest('hex');
const isTranscript = (f) => f.endsWith('.json') && !/\.(check|rejected)\.json$/.test(f);

export function listFiles(split, dir = DATA_DIR) {
  const d = path.join(dir, split);
  if (!existsSync(d)) return [];
  return readdirSync(d).filter(isTranscript).sort();
}

/** sha256 per file (raw bytes, CRLF normalised to LF so a git autocrlf checkout hashes the same) + dataset hash. */
export function hashSplit(split, dir = DATA_DIR) {
  const files = {};
  for (const f of listFiles(split, dir)) files[f] = sha(readFileSync(path.join(dir, split, f), 'utf8').replace(/\r\n/g, '\n'));
  const datasetHash = sha(Object.entries(files).map(([f, h]) => `${f}:${h}`).join('\n'));
  return { files, datasetHash };
}

export function writeManifest(split, dir = DATA_DIR, metaDir = dir, extra = {}) {
  const m = { version: 'emberbench-1', split, createdAt: new Date().toISOString(), ...extra, ...hashSplit(split, dir) };
  writeFileSync(path.join(metaDir, `${split}.manifest.json`), JSON.stringify(m, null, 2) + '\n');
  return m;
}

/** Throws if the split's files differ from its manifest (added, removed or changed). */
export function verifyManifest(split, dir = DATA_DIR, metaDir = dir) {
  const mf = path.join(metaDir, `${split}.manifest.json`);
  if (!existsSync(mf)) { if (split === 'test') throw new Error('test split has no manifest (data/test.manifest.json) — refusing to run'); return null; }
  const want = JSON.parse(readFileSync(mf, 'utf8'));
  const got = hashSplit(split, dir);
  const problems = [];
  for (const [f, h] of Object.entries(want.files)) if (!got.files[f]) problems.push(`missing ${f}`); else if (got.files[f] !== h) problems.push(`changed ${f}`);
  for (const f of Object.keys(got.files)) if (!want.files[f]) problems.push(`added ${f}`);
  if (problems.length) throw new Error(`${split} split does not match its manifest: ${problems.join(', ')}`);
  return want;
}

export function loadSplit(split, dir = DATA_DIR) {
  return listFiles(split, dir).map((f) => {
    const t = JSON.parse(readFileSync(path.join(dir, split, f), 'utf8'));
    t.split = split;
    return t;
  });
}

/** Scenario-disjointness: ids, mosaic circles and legacy sources may not appear in both splits. */
export function checkDisjoint(dev, test) {
  const key = (t) => [t.id, t.circle && `circle:${t.circle}`, t.source && t.source !== 'generated' && `src:${t.source}`].filter(Boolean);
  const a = new Set(dev.flatMap(key));
  const clash = [...new Set(test.flatMap(key))].filter((k) => a.has(k));
  if (clash.length) throw new Error(`dev/test overlap: ${clash.join(', ')}`);
  return true;
}

export function readSeal(dir = DATA_DIR) {
  const f = path.join(dir, 'test.seal.json');
  return existsSync(f) ? JSON.parse(readFileSync(f, 'utf8')) : null;
}
export function writeSeal(rec, dir = DATA_DIR) {
  writeFileSync(path.join(dir, 'test.seal.json'), JSON.stringify({ sealedAt: new Date().toISOString(), ...rec }, null, 2) + '\n');
}

/** Mosaic circles in a split: [{circle, sessions:[t…] ordered}] */
export function circles(ts) {
  const m = new Map();
  for (const t of ts) if (t.circle) { if (!m.has(t.circle)) m.set(t.circle, []); m.get(t.circle).push(t); }
  return [...m].map(([circle, s]) => ({ circle, sessions: s.sort((x, y) => x.session - y.session) }));
}
