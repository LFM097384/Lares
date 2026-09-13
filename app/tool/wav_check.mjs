// SPIKE ONLY — independent verification of a captured WAV.
// Deliberately does NOT reuse the harness's Dart math: this is a second opinion
// on sample rate honesty, computed straight from the file bytes.
// usage: node spike_wav_check.mjs <path.wav>
import fs from 'node:fs';

const path = process.argv[2];
const buf = fs.readFileSync(path);

// --- parse RIFF header strictly ---
const riff = buf.toString('ascii', 0, 4);
const wave = buf.toString('ascii', 8, 12);
const fmtId = buf.toString('ascii', 12, 16);
const audioFormat = buf.readUInt16LE(20);
const channels = buf.readUInt16LE(22);
const sampleRate = buf.readUInt32LE(24);
const byteRate = buf.readUInt32LE(28);
const blockAlign = buf.readUInt16LE(32);
const bits = buf.readUInt16LE(34);
const dataId = buf.toString('ascii', 36, 40);
const dataLen = buf.readUInt32LE(40);

console.log(`file=${path}`);
console.log(`  fileBytes=${buf.length}`);
console.log(`  RIFF="${riff}" WAVE="${wave}" fmt="${fmtId}" data="${dataId}"`);
console.log(`  audioFormat=${audioFormat} (1=PCM) channels=${channels} sampleRate=${sampleRate}`);
console.log(`  byteRate=${byteRate} blockAlign=${blockAlign} bitsPerSample=${bits} dataLen=${dataLen}`);
const hdrOk = riff === 'RIFF' && wave === 'WAVE' && fmtId === 'fmt ' && dataId === 'data'
  && audioFormat === 1 && bits === 16 && byteRate === sampleRate * channels * 2
  && blockAlign === channels * 2 && dataLen === buf.length - 44;
console.log(`  HEADER_VALID=${hdrOk}`);

const n = Math.floor(dataLen / 2);
const x = new Float64Array(n);
for (let i = 0; i < n; i++) x[i] = buf.readInt16LE(44 + i * 2);

// --- stats ---
let sum = 0, sumSq = 0, peak = 0, nz = 0, mn = 32767, mx = -32768;
for (let i = 0; i < n; i++) {
  const v = x[i];
  sum += v; sumSq += v * v;
  if (Math.abs(v) > peak) peak = Math.abs(v);
  if (v !== 0) nz++;
  if (v < mn) mn = v;
  if (v > mx) mx = v;
}
const mean = sum / n;
const rms = Math.sqrt(sumSq / n);
const dur = n / sampleRate;
console.log(`  samples=${n} durationSec=${dur.toFixed(3)}`);
console.log(`  rms=${rms.toFixed(2)} peak=${peak} min=${mn} max=${mx} mean=${mean.toFixed(2)} nonZero=${nz} (${(nz * 100 / n).toFixed(2)}%)`);

// --- DC-removed copy ---
const y = new Float64Array(n);
for (let i = 0; i < n; i++) y[i] = x[i] - mean;

// --- Goertzel over the WHOLE capture, 0.5 Hz grid, 50..2000 Hz ---
function goertzel(sig, from, len, freq, fs) {
  const w = (2 * Math.PI * freq) / fs;
  const c = 2 * Math.cos(w);
  let s0 = 0, s1 = 0, s2 = 0;
  for (let i = 0; i < len; i++) { s0 = sig[from + i] + c * s1 - s2; s2 = s1; s1 = s0; }
  return Math.sqrt(s1 * s1 + s2 * s2 - c * s1 * s2) / len;
}
let best = 0, bestMag = -1;
const spectrum = [];
for (let f = 50; f <= 2000; f += 0.5) {
  const m = goertzel(y, 0, n, f, sampleRate);
  spectrum.push([f, m]);
  if (m > bestMag) { bestMag = m; best = f; }
}
console.log(`  GOERTZEL_FULL_CAPTURE peakHz=${best} mag=${bestMag.toExponential(4)}`);
const top = [...spectrum].sort((a, b) => b[1] - a[1]).slice(0, 200);
const picked = [];
for (const [f, m] of top) { if (!picked.some(([pf]) => Math.abs(pf - f) < 20)) picked.push([f, m]); if (picked.length >= 3) break; }
console.log('  top3=' + picked.map(([f, m]) => `${f}Hz(${m.toExponential(3)})`).join(' '));

// --- energy concentration: how much total power sits near the peak ---
let near = 0, total = 0;
for (const [f, m] of spectrum) { const p = m * m; total += p; if (Math.abs(f - best) <= 15) near += p; }
console.log(`  energyWithin15HzOfPeak=${(near * 100 / total).toFixed(2)}%`);

// --- per-second Goertzel: is the tone stable across the capture? ---
const secs = Math.floor(n / sampleRate);
const perSec = [];
for (let s = 0; s < secs; s++) {
  let bf = 0, bm = -1;
  for (let f = 300; f <= 1200; f += 1) {
    const m = goertzel(y, s * sampleRate, sampleRate, f, sampleRate);
    if (m > bm) { bm = m; bf = f; }
  }
  let ss = 0;
  for (let i = 0; i < sampleRate; i++) { const v = y[s * sampleRate + i]; ss += v * v; }
  perSec.push(`s${s}=${bf}Hz/rms${Math.sqrt(ss / sampleRate).toFixed(0)}`);
}
console.log('  perSecondPeak: ' + perSec.join(' '));

// --- the decisive interpretation ---
const cands = [
  ['440 honored (16k real)', 440],
  ['146.67 => 48k data mislabeled as 16k', 440 * 16000 / 48000],
  ['880 honored (16k real)', 880],
  ['293.33 => 48k data mislabeled as 16k', 880 * 16000 / 48000],
];
let verdict = 'INCONCLUSIVE';
for (const [label, target] of cands) {
  if (Math.abs(best - target) / target <= 0.05) { verdict = label; break; }
}
console.log(`  >>> INDEPENDENT VERDICT: measured ${best} Hz => ${verdict}`);
