// Lets `node --test server/bots/anonym-agent/` work: Node 24 resolves a directory arg as a module
// (this index.js), which imports every test/*.test.mjs. Not the agent entry — that is index.mjs.
import { readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const here = join(dirname(fileURLToPath(import.meta.url)), 'test');
for (const f of readdirSync(here).filter((x) => x.endsWith('.test.mjs')).sort()) await import(pathToFileURL(join(here, f)).href);
