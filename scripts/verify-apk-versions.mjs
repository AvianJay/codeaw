import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import { basename, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export function validateApkVersion(badging, version, buildNumber, expectedAbis) {
  const packageLine = badging.split(/\r?\n/).find(line => line.startsWith('package:'));
  const fields = Object.fromEntries([...String(packageLine).matchAll(/(\w+)='([^']*)'/g)]
    .map(match => [match[1], match[2]]));
  if (fields.name !== 'tw.avianjay.codeaw' || fields.versionName !== version ||
      fields.versionCode !== String(buildNumber)) {
    throw new Error(`APK version mismatch: expected ${version}+${buildNumber}, received ${fields.versionName ?? '?'}+${fields.versionCode ?? '?'}`);
  }
  if (expectedAbis) {
    const nativeLine = badging.split(/\r?\n/).find(line => line.startsWith('native-code:')) ?? '';
    const abis = [...nativeLine.matchAll(/'([^']*)'/g)].map(match => match[1]).sort();
    if (abis.join(',') !== [...expectedAbis].sort().join(',')) {
      throw new Error(`APK ABI mismatch: expected ${expectedAbis.join(',')}, received ${abis.join(',') || '?'}`);
    }
  }
}

const APK_ABIS = {
  'codeaw-universal.apk': ['armeabi-v7a', 'arm64-v8a', 'x86_64'],
  'codeaw-armeabi-v7a.apk': ['armeabi-v7a'],
  'codeaw-arm64-v8a.apk': ['arm64-v8a'],
  'codeaw-x86_64.apk': ['x86_64'],
};

function findAapt() {
  if (process.env.AAPT) return process.env.AAPT;
  const sdk = process.env.ANDROID_HOME ?? process.env.ANDROID_SDK_ROOT;
  if (!sdk) throw new Error('Set ANDROID_HOME or AAPT to verify APK versions');
  const directory = join(sdk, 'build-tools');
  const versions = readdirSync(directory).filter(version => /^\d+(\.\d+)+$/.test(version))
    .sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
  for (const version of versions) {
    const executable = join(directory, version, process.platform === 'win32' ? 'aapt.exe' : 'aapt');
    if (existsSync(executable)) return executable;
  }
  throw new Error('Android build-tools aapt was not found');
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [version, buildNumber, ...apks] = process.argv.slice(2);
  if (!version || !/^\d+$/.test(buildNumber ?? '') || !apks.length) {
    throw new Error('Usage: verify-apk-versions.mjs VERSION BUILD_NUMBER APK...');
  }
  const aapt = findAapt();
  for (const apk of apks) {
    validateApkVersion(execFileSync(aapt, ['dump', 'badging', apk], { encoding: 'utf8' }), version, buildNumber, APK_ABIS[basename(apk)]);
    process.stdout.write(`Verified ${basename(apk)}: ${version}+${buildNumber}\n`);
  }
}
