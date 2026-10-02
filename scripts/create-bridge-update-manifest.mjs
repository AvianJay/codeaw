import { writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createManifest } from './create-update-manifest.mjs';

export const BRIDGE_UPDATE_FILES = [
  ...['windows-x64', 'windows-arm64'].flatMap(target => [
    [target, `codeaw-bridge-${target}.zip`],
    [`${target}-setup`, `codeaw-bridge-${target}-setup.exe`],
  ]),
  ...['linux-x64', 'linux-arm64', 'linux-x64-musl', 'linux-arm64-musl', 'macos-x64', 'macos-arm64']
    .map(target => [target, `codeaw-bridge-${target}.tar.gz`]),
];

export function createBridgeUpdateManifest(metadata) {
  return createManifest(metadata, BRIDGE_UPDATE_FILES);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [directory, repository, channel, version, buildNumber, tag, commit] = process.argv.slice(2);
  const manifest = createBridgeUpdateManifest({ directory, repository, channel, version, buildNumber: Number(buildNumber), tag, commit });
  writeFileSync(resolve(directory, 'bridge-update.json'), `${JSON.stringify(manifest, null, 2)}\n`);
}
