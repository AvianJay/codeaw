import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { test } from 'node:test';
import { createUpdateManifest } from './create-update-manifest.mjs';

test('published manifest matches the actual APK and IPA for both channels', () => {
  const directory = mkdtempSync(join(tmpdir(), 'codeaw-manifest-test-'));
  try {
    writeFileSync(join(directory, 'codeaw-universal.apk'), 'apk');
    writeFileSync(join(directory, 'codeaw-ios-unsigned.ipa'), 'ipa');
    for (const channel of ['nightly', 'release']) {
      const tag = channel === 'nightly' ? 'nightly' : 'v0.2.0';
      const manifest = createUpdateManifest({ directory, repository: 'AvianJay/codeaw', channel, version: '0.2.0', buildNumber: 42, tag, commit: 'abcdef' });
      assert.equal(manifest.channel, channel);
      assert.equal(manifest.buildNumber, 42);
      assert.equal(manifest.assets.android.sha256, createHash('sha256').update('apk').digest('hex'));
      assert.equal(manifest.assets.ios.sha256, createHash('sha256').update('ipa').digest('hex'));
      assert.equal(manifest.assets.android.size, 3);
      assert.equal(manifest.assets.android.url, `https://github.com/AvianJay/codeaw/releases/download/${tag}/codeaw-universal.apk`);
    }
    assert.throws(() => createUpdateManifest({ directory, repository: 'AvianJay/codeaw', channel: 'release', version: '0.2.0', buildNumber: 42, tag: 'nightly' }), /Invalid/);
    writeFileSync(join(directory, 'codeaw-ios-unsigned.ipa'), '');
    assert.throws(() => createUpdateManifest({ directory, repository: 'AvianJay/codeaw', channel: 'nightly', version: '0.2.0', buildNumber: 42, tag: 'nightly' }), /Empty/);
  } finally {
    assert.equal(dirname(resolve(directory)), resolve(tmpdir()));
    assert.ok(basename(directory).startsWith('codeaw-manifest-test-'));
    rmSync(directory, { recursive: true, force: true });
  }
});
