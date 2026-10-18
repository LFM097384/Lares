import { test } from 'node:test';
import assert from 'node:assert/strict';
import { canonicalJSON, sha256hex, verifyEd25519, generateEd25519, signEd25519, rawPublicKeyB64, approvalMessage } from '../core/crypto.mjs';

test('canonicalJSON sorts keys recursively, no whitespace', () => {
  assert.equal(canonicalJSON({ b: 1, a: { d: [3, { z: 1, y: 2 }], c: 'x' } }), '{"a":{"c":"x","d":[3,{"y":2,"z":1}]},"b":1}');
  assert.equal(canonicalJSON({ a: undefined, b: null }), '{"b":null}');
  assert.equal(canonicalJSON('中文'), '"中文"');
  assert.throws(() => canonicalJSON({ x: NaN }));
});

test('sha256hex', () => {
  assert.equal(sha256hex('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

test('verifyEd25519 accepts raw b64, PEM and KeyObject; rejects tampering', () => {
  const kp = generateEd25519();
  const msg = approvalMessage({ sid: 's', draftId: 'd', draftHash: 'h', nonce: 'n' });
  assert.equal(msg, '{"draftHash":"h","draftId":"d","nonce":"n","sid":"s"}');
  const sig = signEd25519(kp.privateKey, msg);
  assert.equal(Buffer.from(kp.pubB64, 'base64').length, 32);
  assert.ok(verifyEd25519(kp.pubB64, msg, sig));
  assert.ok(verifyEd25519(kp.pem, msg, sig));
  assert.ok(verifyEd25519(kp.publicKey, msg, sig));
  assert.equal(rawPublicKeyB64(kp.pem), kp.pubB64);
  assert.equal(verifyEd25519(kp.pubB64, msg + 'x', sig), false);
  assert.equal(verifyEd25519(generateEd25519().pubB64, msg, sig), false);
  assert.equal(verifyEd25519('garbage', msg, sig), false);
  assert.equal(verifyEd25519(kp.pubB64, msg, 'AAAA'), false);
});
