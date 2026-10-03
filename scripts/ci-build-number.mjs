import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

// Older Flutter split APKs used run + 1000/2000/4000. Start above those
// ranges so existing clients detect the update and Android accepts it.
export const BUILD_NUMBER_BASE = 5000;
const MAX_VERSION_CODE = 2100000000;

export function ciBuildNumber(runNumber) {
  const run = Number(runNumber);
  if (!Number.isSafeInteger(run) || run <= 0 || run > MAX_VERSION_CODE - BUILD_NUMBER_BASE) {
    throw new Error('Invalid CI run number');
  }
  return BUILD_NUMBER_BASE + run;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  process.stdout.write(`${ciBuildNumber(process.argv[2])}\n`);
}
