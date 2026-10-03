import assert from 'node:assert/strict';
import { test } from 'node:test';
import { validateApkVersion } from './verify-apk-versions.mjs';

const badging = (name, version, build) => `package: name='${name}' versionCode='${build}' versionName='${version}'\nsdkVersion:'24'\n`;

test('accepts exact package and version metadata', () => {
  assert.doesNotThrow(() => validateApkVersion(badging('tw.avianjay.codeaw', '0.1.0', 5017), '0.1.0', 5017));
});

test('rejects ABI offsets, stale APKs, wrong app IDs and absent metadata', () => {
  for (const build of [17, 1017, 2017, 4017, 6017, 7017, 9017]) {
    assert.throws(() => validateApkVersion(badging('tw.avianjay.codeaw', '0.1.0', build), '0.1.0', 5017), /mismatch/);
  }
  assert.throws(() => validateApkVersion(badging('tw.avianjay.codeaw', '0.2.0', 5017), '0.1.0', 5017), /mismatch/);
  assert.throws(() => validateApkVersion(badging('other.app', '0.1.0', 5017), '0.1.0', 5017), /mismatch/);
  assert.throws(() => validateApkVersion('', '0.1.0', 5017), /mismatch/);
});

test('per-ABI packages cannot advertise architectures with missing Flutter engines', () => {
  const metadata = badging('tw.avianjay.codeaw', '0.1.0', 5017);
  assert.doesNotThrow(() => validateApkVersion(`${metadata}native-code: 'arm64-v8a'\n`, '0.1.0', 5017, ['arm64-v8a']));
  assert.throws(() => validateApkVersion(`${metadata}native-code: 'armeabi-v7a' 'arm64-v8a' 'x86_64'\n`, '0.1.0', 5017, ['armeabi-v7a']), /ABI mismatch/);
  assert.throws(() => validateApkVersion(metadata, '0.1.0', 5017, ['arm64-v8a']), /ABI mismatch/);
});
