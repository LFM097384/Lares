import { test } from 'node:test';
import assert from 'node:assert/strict';
import { redactPII } from '../core/gate/l1.mjs';

test('L1: usernames in metadata/account context are redacted, ordinary words kept', () => {
  assert.doesNotMatch(redactPII("the PDF metadata shows author 'zlei' and a creation date", []), /zlei/);
  assert.doesNotMatch(redactPII('用户名是zlei', []), /zlei/);
  assert.doesNotMatch(redactPII('username: jdoe', []), /jdoe/);
  assert.equal(redactPII('the author of the report argued', []), 'the author of the report argued');
  assert.equal(redactPII('the account was closed', []), 'the account was closed');
});
