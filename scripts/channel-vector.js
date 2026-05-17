#!/usr/bin/env node
// Generator for the cross-language AES-256-GCM test vector.
// Run once from the umbrella root:  node scripts/channel-vector.js
// Output:  scripts/channel-vector.json
//
// Every service's unit test imports the JSON and asserts that running its own
// AES-256-GCM implementation against (key, iv, plaintext, aad) produces the
// same (ciphertext, tag) — proving Rust / Go / TS / Python / Java agree on
// the wire format before any service-to-service test is attempted.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const key = Buffer.from(
  '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  'hex',
); // 32 bytes
const iv = Buffer.from('0a0b0c0d0e0f101112131415', 'hex'); // 12 bytes
const aad = Buffer.alloc(0);
const plaintext = Buffer.from(
  JSON.stringify({ hello: 'world', tenant: 'demo', n: 42 }),
  'utf8',
);

const cipher = crypto.createCipheriv('aes-256-gcm', key, iv, { authTagLength: 16 });
if (aad.length > 0) cipher.setAAD(aad);
const ct = Buffer.concat([cipher.update(plaintext), cipher.final()]);
const tag = cipher.getAuthTag();

const envelope = {
  v: 1,
  iv: iv.toString('base64'),
  ct: ct.toString('base64'),
  tag: tag.toString('base64'),
};

const vector = {
  alg: 'AES-256-GCM',
  notes:
    'Fixed AES-256-GCM test vector used by every service unit test to prove ' +
    'cross-language interop on the secure-channel wire format (envelope below). ' +
    'Regenerate with: node scripts/channel-vector.js',
  key_b64: key.toString('base64'),
  iv_b64: iv.toString('base64'),
  aad_b64: aad.toString('base64'),
  plaintext_b64: plaintext.toString('base64'),
  ciphertext_b64: ct.toString('base64'),
  tag_b64: tag.toString('base64'),
  envelope,
};

const outPath = path.join(__dirname, 'channel-vector.json');
fs.writeFileSync(outPath, JSON.stringify(vector, null, 2) + '\n');
console.log('Wrote ' + outPath);
