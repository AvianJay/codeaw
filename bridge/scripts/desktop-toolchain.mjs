import path from 'node:path';
import { createHash } from 'node:crypto';

const generators = new Map([
  [17, 'Visual Studio 17 2022'],
  [18, 'Visual Studio 18 2026'],
]);

export function selectDesktopStudio(instance) {
  const major = Number(instance?.installationVersion?.split('.')[0]);
  const generator = generators.get(major);
  if (!generator || !instance?.installationPath) {
    throw new Error('A supported Visual Studio 2022 or 2026 C++ installation is required.');
  }
  return { major, generator, directory: instance.installationPath };
}

export function desktopBuildDirectory(cache, arch, studio, webrtc) {
  const instance = createHash('sha256').update(studio.directory.toLowerCase()).digest('hex').slice(0, 8);
  return path.join(cache, `native-${arch}-vs${studio.major}-${instance}${webrtc ? '' : '-basic'}`);
}

export function desktopConfigureArgs({ source, build, arch, studio, webrtc, cmakeVersion }) {
  const args = ['-S', source, '-B', build, '-G', studio.generator, '-A', arch === 'arm64' ? 'ARM64' : 'x64',
    `-DCMAKE_GENERATOR_INSTANCE=${studio.directory}`, `-DCODEAW_WEBRTC=${webrtc ? 'ON' : 'OFF'}`];
  // The pinned third-party projects include pre-CMake-4 policy declarations.
  if (Number(cmakeVersion.split('.')[0]) >= 4) args.push('-DCMAKE_POLICY_VERSION_MINIMUM=3.10');
  return args;
}

export function desktopCmakeVersion(studio) { return studio.major >= 18 ? '4.2.3' : '3.31.6'; }
