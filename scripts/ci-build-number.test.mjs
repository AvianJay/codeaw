import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ciBuildNumber } from './ci-build-number.mjs';

test('new builds upgrade legacy universal and all ABI APKs', () => {
  for (const previousRun of [1, 14, 999, 1000, 12345]) {
    const next = ciBuildNumber(previousRun + 1);
    for (const offset of [0, 1000, 2000, 4000]) {
      assert.ok(next > previousRun + offset);
    }
    assert.equal(ciBuildNumber(previousRun + 2), next + 1);
  }
  assert.equal(ciBuildNumber('17'), 5017);
});

test('rejects invalid build numbers and respects the Android version code limit', () => {
  for (const value of [undefined, '', 'abc', 0, -1, 1.5, Infinity, 2100000000]) {
    assert.throws(() => ciBuildNumber(value), /Invalid/);
  }
  assert.equal(ciBuildNumber(2099995000), 2100000000);
});
