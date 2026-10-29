// EmberBench: offline end-to-end of the harness (core Ember in mock mode + mock attacker/judge).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runTask } from '../bench/harness.mjs';
import { aggregate, judgeThresholds } from '../bench/trustcard.mjs';
import { makeLLM } from '../bench/providers.mjs';
import { mapLegacy } from '../bench/gen/import-legacy.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));

test('runTask: +L4 / raw / ideas-only records, raw leaks, +L4 releases via k approvals', async () => {
  const t = mapLegacy(JSON.parse(readFileSync(path.join(HERE, '..', 'eval', 'data', 'bookclub.json'), 'utf8')), 'dev');
  t.questions = [{ id: 'q1', askerId: t.roster[0].id, q: '刚才讨论了什么？', answer: t.gold.ideas[0].text }];
  const attacker = makeLLM('mock:a'), judge = makeLLM('mock:j');
  const { records } = await runTask({ key: t.id, sessions: [t] }, { gate: null, attacker, judge, configs: ['+L4', 'ideas-only', 'raw'], seed: 1 });
  const by = Object.fromEntries(records.map((r) => [r.config, r]));
  assert.ok(by['+L4'].release.length > 0, 'core session released after k approvals');
  assert.equal(by['+L4'].answers.length, 1);
  assert.ok(by.raw.leaks.names > 0, 'raw config leaks names (sanity)');
  assert.ok(by['+L4'].leaks.names < by.raw.leaks.names);
  assert.equal(typeof by['ideas-only'].attackFull, 'number');
  const v = judgeThresholds(aggregate(records, []));
  assert.equal(v.length, 12);
});
