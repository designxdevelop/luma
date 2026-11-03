// Packs the headless Luma Bridge: release/luma-bridge-<version>.tar.gz with only the compiled
// Electron-free modules it loads. Needs Node 22.12+ on the target; no npm install, no native modules.
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';

const { version, license, engines } = JSON.parse(readFileSync('package.json', 'utf8'));
const stage = join('release', 'luma-bridge');
// Electron entry points the bridge never loads.
const electronOnly = new Set(['main.js', 'preload.js', 'capture.js']);
rmSync(stage, { recursive: true, force: true });
mkdirSync(stage, { recursive: true });
for (const dir of ['bridge', 'core', 'main', 'shared']) {
  cpSync(join('dist', dir), join(stage, 'dist', dir), { recursive: true, filter: (src) => !(dir === 'main' && electronOnly.has(src.split(/[\\/]/).pop())) });
}
cpSync('LICENSE', join(stage, 'LICENSE'));
writeFileSync(join(stage, 'package.json'), `${JSON.stringify({ name: 'luma-bridge', version, private: true, license, engines, bin: { 'luma-bridge': 'dist/bridge/cli.js' } }, null, 2)}\n`);
const out = `luma-bridge-${version}.tar.gz`;
// --no-xattrs: macOS provenance attributes would otherwise warn on every Linux extract.
execFileSync('tar', ['--no-xattrs', '-czf', out, 'luma-bridge'], { cwd: 'release', stdio: 'inherit' });
console.log(`release/${out}  (run: node luma-bridge/dist/bridge/cli.js help)`);
