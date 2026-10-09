import assert from 'node:assert/strict';
import test from 'node:test';
import { selectDesktopStudio, desktopBuildDirectory, desktopConfigureArgs, desktopCmakeVersion } from '../bridge/scripts/desktop-toolchain.mjs';

const vs2022 = { installationVersion: '17.14.36212.18', installationPath: 'C:/Program Files/Visual Studio/2022/BuildTools' };
const vs2026 = { installationVersion: '18.10.1', installationPath: 'C:/Program Files/Microsoft Visual Studio/18/Enterprise' };

test('VS 2026 ARM64 selects its own generator and instance instead of requiring v143', () => {
  const studio = selectDesktopStudio(vs2026);
  const args = desktopConfigureArgs({ source: 'source with spaces', build: 'build', arch: 'arm64', studio, webrtc: true, cmakeVersion: '4.3.1' });
  assert.equal(args[args.indexOf('-G') + 1], 'Visual Studio 18 2026');
  assert.equal(args[args.indexOf('-A') + 1], 'ARM64');
  assert.ok(args.includes(`-DCMAKE_GENERATOR_INSTANCE=${vs2026.installationPath}`));
  assert.ok(args.includes('-DCMAKE_POLICY_VERSION_MINIMUM=3.10'));
  assert.ok(!args.some((arg) => arg.includes('2022') || arg.includes('v143')));
  assert.equal(desktopCmakeVersion(studio), '4.2.3');
});

test('existing VS 2022 x64 builds retain their supported generator', () => {
  const studio = selectDesktopStudio(vs2022);
  const args = desktopConfigureArgs({ source: 'source', build: 'build', arch: 'x64', studio, webrtc: false, cmakeVersion: '3.31.6' });
  assert.equal(args[args.indexOf('-G') + 1], 'Visual Studio 17 2022');
  assert.equal(args[args.indexOf('-A') + 1], 'x64');
  assert.ok(args.includes('-DCODEAW_WEBRTC=OFF'));
  assert.ok(!args.some((arg) => arg.includes('POLICY_VERSION')));
  assert.equal(desktopCmakeVersion(studio), '3.31.6');
});

test('architecture, VS version and instance have separate CMake caches', () => {
  const first = selectDesktopStudio(vs2022), second = selectDesktopStudio(vs2026);
  const other = selectDesktopStudio({ ...vs2026, installationPath: 'C:/Other Visual Studio' });
  const dirs = new Set([
    desktopBuildDirectory('cache', 'x64', first, true),
    desktopBuildDirectory('cache', 'arm64', first, true),
    desktopBuildDirectory('cache', 'arm64', second, true),
    desktopBuildDirectory('cache', 'arm64', other, true),
    desktopBuildDirectory('cache', 'arm64', second, false),
  ]);
  assert.equal(dirs.size, 5);
  assert.equal(desktopBuildDirectory('cache', 'x64', first, true), desktopBuildDirectory('cache', 'x64', selectDesktopStudio({ ...vs2022, installationPath: vs2022.installationPath.toUpperCase() }), true));
});

test('missing or unsupported C++ installations fail before invoking CMake', () => {
  assert.throws(() => selectDesktopStudio(undefined), /C\+\+ installation/);
  assert.throws(() => selectDesktopStudio({ ...vs2026, installationVersion: '19.0' }), /supported Visual Studio/);
});
