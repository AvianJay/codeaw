import { writeFileSync } from 'node:fs';

const [version, build, channel, repository, target] = process.argv.slice(2);
if (!/^\d+\.\d+\.\d+$/.test(version ?? '') || !Number.isSafeInteger(Number(build)) || Number(build) <= 0 ||
    !['release', 'nightly'].includes(channel) || !/^[\w.-]+\/[\w.-]+$/.test(repository ?? '') ||
    !/^(windows|linux|macos)-(x64|arm64)(-musl)?$/.test(target ?? '')) {
  throw new Error('Invalid bridge build metadata');
}
writeFileSync(new URL('../src/version.ts', import.meta.url), [
  `export const VERSION = ${JSON.stringify(version)};`,
  `export const BUILD_NUMBER = ${Number(build)};`,
  `export const UPDATE_CHANNEL: "release" | "nightly" = ${JSON.stringify(channel)};`,
  `export const UPDATE_REPOSITORY = ${JSON.stringify(repository)};`,
  `export const BUILD_TARGET = ${JSON.stringify(target)};`,
  '',
].join('\n'));
