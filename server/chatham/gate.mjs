#!/usr/bin/env node
// Usage: node gate.mjs <file.json> [--mock] [--layers L0,L1,L2,L3,L4]
import { readFile } from 'node:fs/promises';
import { runGate } from './lib/gate.mjs';

const argv = process.argv.slice(2);
const file = argv.find((a, i) => !a.startsWith('--') && argv[i - 1] !== '--layers');
if (!file) { console.error('usage: node gate.mjs <file.json> [--mock] [--layers L0,L1,...]'); process.exit(2); }
const opts = {};
if (argv.includes('--mock')) opts.mock = true;
const li = argv.indexOf('--layers');
if (li >= 0) opts.layers = (argv[li + 1] || '').split(',').map((s) => s.trim()).filter(Boolean);

const t = JSON.parse(await readFile(file, 'utf8'));
const { digest, claims, meta } = await runGate(t, opts);
process.stdout.write(digest);
console.error(`[gate] layers=${meta.layers.join(',') || 'raw'} mock=${meta.mock} claims=${claims.length} llmCalls=${meta.llmCalls} tokens=${meta.promptTokens}+${meta.completionTokens} verifierRounds=${meta.verifierRounds} dropped=${meta.dropped} ms=${meta.ms}`);
