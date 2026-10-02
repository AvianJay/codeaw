import { createHash } from 'node:crypto';
import { readFileSync, statSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export function createManifest({ directory, repository, channel, version, buildNumber, tag, commit }, files) {
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository) ||
      !['release', 'nightly'].includes(channel) ||
      !/^\d+\.\d+\.\d+$/.test(version) ||
      !Number.isSafeInteger(buildNumber) || buildNumber <= 0 ||
      (channel === 'nightly' ? tag !== 'nightly' : tag !== `v${version}`)) {
    throw new Error('Invalid update build metadata');
  }
  const base = `https://github.com/${repository}/releases/download/${tag}`;
  const assets = {};
  for (const [platform, name] of files) {
    const path = resolve(directory, name);
    const size = statSync(path).size;
    if (size <= 0) throw new Error(`Empty update asset: ${name}`);
    assets[platform] = {
      url: `${base}/${name}`,
      sha256: createHash('sha256').update(readFileSync(path)).digest('hex'),
      size,
    };
  }
  return {
    schemaVersion: 1,
    channel,
    version,
    buildNumber,
    commit,
    releaseUrl: `https://github.com/${repository}/releases/tag/${tag}`,
    assets,
  };
}

export function createUpdateManifest(metadata) {
  return createManifest(metadata, [['android', 'codeaw-universal.apk'], ['ios', 'codeaw-ios-unsigned.ipa']]);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [directory, repository, channel, version, buildNumber, tag, commit] = process.argv.slice(2);
  const manifest = createUpdateManifest({ directory, repository, channel, version, buildNumber: Number(buildNumber), tag, commit });
  writeFileSync(resolve(directory, 'app-update.json'), `${JSON.stringify(manifest, null, 2)}\n`);
}
