// Lets `node --test server/anonym-agent/` work: Node 24 resolves a directory arg as a module
// (this index.js), which loads test/index.js → every test/*.test.mjs.
// Not a runtime entry point: import core/index.mjs for the API.
await import('./test/index.js');
