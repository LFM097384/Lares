// Lets `node --test server/anonym-agent/test/` work: Node 24 resolves a directory arg as a module
// (index.js), so this ESM entry imports every *.test.mjs in this folder (incl. gate*.test.mjs).
import { readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
for (const f of readdirSync(here).filter((x) => x.endsWith('.test.mjs')).sort()) await import(pathToFileURL(join(here, f)).href);
