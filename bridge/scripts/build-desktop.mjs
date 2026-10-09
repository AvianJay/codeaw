import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { createHash } from 'node:crypto';
import os from 'node:os';
const root = fileURLToPath(new URL('../', import.meta.url));
const nativeCache = process.env.CODEAW_NATIVE_BUILD_DIR ?? path.join(os.tmpdir(), 'codeaw-native', createHash('sha256').update(root).digest('hex').slice(0, 12));
const { values } = parseArgs({ options: { arch: { type: 'string', default: process.arch === 'arm64' ? 'arm64' : 'x64' },
  'out-dir': { type: 'string', default: 'dist/assets' }, 'no-webrtc': { type: 'boolean', default: false } } });
if (process.platform !== 'win32') throw new Error('Build the Windows desktop helper on Windows.');
if (!['x64', 'arm64'].includes(values.arch)) throw new Error('Unsupported desktop architecture');
function run(command, args, capture = false) {
  const r = spawnSync(command, args, { windowsHide: true, cwd: root, encoding: 'utf8', stdio: capture ? 'pipe' : 'inherit' });
  if (r.error || r.status !== 0) throw new Error(`${path.basename(command)} failed${r.error ? ': ' + r.error.message : capture ? ': ' + (r.stderr ?? '') : ''}`);
  return r.stdout?.trim();
}
const vswhere = path.join(process.env['ProgramFiles(x86)'] ?? 'C:/Program Files (x86)', 'Microsoft Visual Studio/Installer/vswhere.exe');
const vs = run(vswhere, ['-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'], true);
const bundled = path.join(vs, 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe');
let cmake = fs.existsSync(bundled) ? bundled : 'cmake';
if (spawnSync(cmake, ['--version'], { windowsHide: true, stdio: 'ignore' }).status !== 0) {
  const version = '3.31.6', name = `cmake-${version}-windows-x86_64`, cache = path.join(nativeCache, 'tools');
  cmake = path.join(cache, name, 'bin/cmake.exe');
  if (!fs.existsSync(cmake)) {
    fs.mkdirSync(cache, { recursive: true });
    const base = `https://github.com/Kitware/CMake/releases/download/v${version}/`;
    const archive = `${name}.zip`;
    const response = await fetch(base + archive); if (!response.ok) throw new Error('Cannot download CMake');
    const bytes = Buffer.from(await response.arrayBuffer());
    const sumsResponse = await fetch(base + `cmake-${version}-SHA-256.txt`); if (!sumsResponse.ok) throw new Error('Cannot verify CMake');
    const sums = await sumsResponse.text(); const expected = sums.split(/\r?\n/).find((line) => line.endsWith(archive))?.split(/\s+/)[0];
    if (!expected || createHash('sha256').update(bytes).digest('hex') !== expected) throw new Error('CMake checksum mismatch');
    const zip = path.join(cache, archive); fs.writeFileSync(zip, bytes);
    const extract = path.join(cache, 'extract.ps1');
    fs.writeFileSync(extract, 'param([string]$Archive,[string]$Destination)\n$ErrorActionPreference="Stop"\nExpand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force\n');
    run('powershell.exe', ['-NoProfile', '-NonInteractive', '-File', extract, '-Archive', zip, '-Destination', cache]);
  }
}
const build = path.join(nativeCache, `native-${values.arch}${values['no-webrtc'] ? '-basic' : ''}`);
run(cmake, ['-S', path.join(root, 'native/windows-desktop'), '-B', build, '-G', 'Visual Studio 17 2022', '-A', values.arch === 'arm64' ? 'ARM64' : 'x64',
  `-DCODEAW_WEBRTC=${values['no-webrtc'] ? 'OFF' : 'ON'}`]);
run(cmake, ['--build', build, '--config', 'Release', '--target', 'codeaw-desktop', '--parallel', '4']);
const out = path.resolve(root, values['out-dir']); fs.mkdirSync(out, { recursive: true });
fs.copyFileSync(path.join(build, 'Release/codeaw-desktop.exe'), path.join(out, 'codeaw-desktop.exe'));
// Source builds find the same helper as release builds.
if (out !== path.join(root, 'dist/assets')) { fs.mkdirSync(path.join(root, 'dist/assets'), { recursive: true }); fs.copyFileSync(path.join(out, 'codeaw-desktop.exe'), path.join(root, 'dist/assets/codeaw-desktop.exe')); }
