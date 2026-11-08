#!/usr/bin/env node
// Reproducible vendored build of kas-mini for the KAS panel (Stage B1, issue #425).
//
// Fetches the pinned web4core source (PROVENANCE.json sourceSha), compiles the KAS-owned
// adapter entries (this directory) inside that tree with esbuild at the version pinned by
// the web4core package-lock, and byte-compares the result with the committed asset.
//
// Usage:
//   node build-vendor.mjs --verify            CI/dev: rebuild from the pinned SHA and
//                                             require a byte-identical committed asset.
//   node build-vendor.mjs                     dev: rebuild and overwrite the committed asset.
//   node build-vendor.mjs --update-provenance dev: additionally refresh PROVENANCE.json
//                                             (hash/bytes/esbuild version) for a sync PR.
// Environment:
//   ESBUILD_BIN=/path/esbuild      use a standalone esbuild binary instead of npm ci.
//   KAS_MINI_SOURCE_DIR=/path/web4core  dev convenience: use an existing checkout that is
//                                  exactly at sourceSha (skips the network fetch). Never
//                                  used by --verify semantics — the SHA is still enforced.
//
// Only PC/CI: routers have no Node.js runtime (issue #425 Phase 0).
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const panelDir = path.resolve(here, '..'); // web/control-center (flat kas-mini-vendor layout)
const committedAsset = path.join(panelDir, 'web', 'kas-mini.js');
const provenancePath = path.join(here, 'PROVENANCE.json');

const flags = new Set(process.argv.slice(2));
const verify = flags.has('--verify');
const updateProvenance = flags.has('--update-provenance');

function fail(message) {
    console.error(`kas-mini vendor build: ${message}`);
    process.exit(1);
}

function gitIn(dir, gitArgs) {
    const res = spawnSync('git', gitArgs, { cwd: dir, encoding: 'utf8' });
    if (res.status !== 0) {
        fail(`git ${gitArgs.join(' ')} failed: ${(res.stderr || res.stdout || '').trim()}`);
    }
    return String(res.stdout || '').trim();
}

const prov = JSON.parse(readFileSync(provenancePath, 'utf8'));
const sourceSha = prov.sourceSha;
if (!/^[0-9a-f]{40}$/.test(sourceSha)) fail(`PROVENANCE.json sourceSha is not a 40-hex SHA: ${sourceSha}`);

// 1. Source tree exactly at the pinned SHA.
let srcDir = process.env.KAS_MINI_SOURCE_DIR || '';
if (srcDir) {
    const head = gitIn(srcDir, ['rev-parse', 'HEAD']);
    if (head !== sourceSha) fail(`KAS_MINI_SOURCE_DIR is at ${head}, expected the pinned ${sourceSha}`);
    console.log(`kas-mini vendor build: source (dev override) ${srcDir} @ ${sourceSha}`);
} else {
    srcDir = path.join(os.tmpdir(), `kas-mini-vendor-${sourceSha.slice(0, 12)}`);
    rmSync(srcDir, { recursive: true, force: true });
    mkdirSync(srcDir, { recursive: true });
    gitIn(srcDir, ['init', '-q']);
    gitIn(srcDir, ['remote', 'add', 'origin', prov.sourceRepo]);
    // GitHub serves arbitrary commit SHAs; the checkout below is verified against the pin,
    // so a fallback through the recorded PR ref cannot weaken the reproducibility contract.
    // Status check, not stdout: `git fetch -q` prints nothing on success.
    let fetchErr = '';
    const tryFetch = (ref) => {
        const res = spawnSync('git', ['fetch', '-q', '--depth', '1', 'origin', ref], { cwd: srcDir, encoding: 'utf8' });
        if (res.status === 0) return true;
        fetchErr = String(res.stderr || res.error || `exit ${res.status}`).trim();
        return false;
    };
    let fetched = tryFetch(sourceSha);
    if (!fetched && prov.sourcePull) fetched = tryFetch(`refs/pull/${prov.sourcePull}/head`);
    if (!fetched) fail(`could not fetch ${sourceSha} from ${prov.sourceRepo}: ${fetchErr}`);
    gitIn(srcDir, ['checkout', '-q', '--detach', 'FETCH_HEAD']);
    const head = gitIn(srcDir, ['rev-parse', 'HEAD']);
    if (head !== sourceSha) fail(`checkout mismatch: got ${head}, expected the pinned ${sourceSha}`);
    console.log(`kas-mini vendor build: source fetched ${prov.sourceRepo} @ ${sourceSha}`);
}

// 2. esbuild at the version locked by the pinned tree (devDependency, package-lock.json).
let esbuildVersion = 'ESBUILD_BIN override';
let esbuildArgs = null;
if (process.env.ESBUILD_BIN) {
    esbuildArgs = [process.env.ESBUILD_BIN];
    const v = spawnSync(process.env.ESBUILD_BIN, ['--version'], { encoding: 'utf8' });
    if (v.status === 0 && String(v.stdout || '').trim()) esbuildVersion = String(v.stdout).trim() + ' (ESBUILD_BIN)';
} else {
    const esbuildPkgBin = path.join(srcDir, 'node_modules', '@esbuild', `${process.platform}-${process.arch}`, 'bin', 'esbuild' + (process.platform === 'win32' ? '.exe' : ''));
    const esbuildShim = path.join(srcDir, 'node_modules', 'esbuild', 'bin', 'esbuild');
    if (!existsSync(esbuildPkgBin) && !existsSync(esbuildShim)) {
        const npmCmd = process.platform === 'win32' ? 'npm.cmd' : 'npm';
        const res = spawnSync(npmCmd, ['ci', '--no-audit', '--no-fund'], { cwd: srcDir, stdio: 'inherit', shell: process.platform === 'win32' });
        if (res.status !== 0) fail(`npm ci failed in the pinned tree (exit ${res.status}); or set ESBUILD_BIN`);
    }
    esbuildVersion = JSON.parse(readFileSync(path.join(srcDir, 'node_modules', 'esbuild', 'package.json'), 'utf8')).version;
    // esbuild's postinstall replaces the JS shim with the native binary in newer
    // versions — exec ELF (ELF, 4-byte magic) / PE (MZ) directly, run only a
    // JS shim through node.
    let binPath = existsSync(esbuildPkgBin) ? esbuildPkgBin : esbuildShim;
    const magic = readFileSync(binPath).subarray(0, 4);
    const isBinary = (magic[0] === 0x7f && magic.toString('latin1', 1) === 'ELF') || magic.toString('latin1', 0, 2) === 'MZ';
    esbuildArgs = isBinary ? [binPath] : [process.execPath, binPath];
}

// 3. KAS-owned adapter entries are compiled from inside the pinned tree.
copyFileSync(path.join(here, 'vendor-entry.js'), path.join(srcDir, 'kas-mini', 'vendor-entry.js'));
copyFileSync(path.join(here, 'kas-mini-mount.js'), path.join(srcDir, 'kas-mini', 'kas-mini-mount.js'));

// 4. Deterministic bundle: same source SHA + same lockfile-pinned esbuild + same flags.
const outFile = verify ? path.join(os.tmpdir(), `kas-mini-verify-${process.pid}.js`) : committedAsset;
const esbuildRes = spawnSync(esbuildArgs[0], [
    ...esbuildArgs.slice(1),
    path.join(srcDir, 'kas-mini', 'vendor-entry.js'),
    '--bundle',
    '--format=iife',
    '--global-name=KasMini',
    '--platform=browser',
    '--minify',
    '--charset=utf8',
    `--outfile=${outFile}`,
], { stdio: 'inherit' });
if (esbuildRes.status !== 0) fail(`esbuild failed (exit ${esbuildRes.status})`);

// 5. Hash and compare.
const built = readFileSync(outFile);
const builtSha = createHash('sha256').update(built).digest('hex');
if (verify) {
    rmSync(outFile, { force: true });
    if (!existsSync(committedAsset)) fail(`committed asset missing: ${committedAsset}`);
    const committed = readFileSync(committedAsset);
    const committedSha = createHash('sha256').update(committed).digest('hex');
    const recorded = prov.files && prov.files['kas-mini.js'];
    const problems = [];
    if (!committed.equals(built)) problems.push(`committed asset ${committedSha} != rebuilt ${builtSha}`);
    if (!recorded || recorded.sha256 !== builtSha) problems.push(`PROVENANCE.json hash ${recorded && recorded.sha256} != rebuilt ${builtSha}`);
    if (!recorded || recorded.bytes !== built.length) problems.push(`PROVENANCE.json bytes ${recorded && recorded.bytes} != rebuilt ${built.length}`);
    if (problems.length) {
        console.error(problems.map(p => `  - ${p}`).join('\n'));
        fail('kas-mini vendor verification FAILED — the committed bundle does not match the pinned source rebuild');
    }
    console.log(`kas-mini vendor verify OK: sha256=${builtSha} (${built.length} bytes, esbuild ${esbuildVersion}, source ${sourceSha})`);
} else {
    writeFileSync(committedAsset, built);
    if (updateProvenance) {
        prov.esbuild = { ...(prov.esbuild || {}), version: esbuildVersion, flags: '--bundle --format=iife --global-name=KasMini --platform=browser --minify --charset=utf8' };
        prov.files = { ...(prov.files || {}), 'kas-mini.js': { sha256: builtSha, bytes: built.length } };
        writeFileSync(provenancePath, JSON.stringify(prov, null, 2) + '\n');
        console.log('kas-mini vendor build: PROVENANCE.json updated');
    }
    console.log(JSON.stringify({
        asset: path.relative(path.resolve(panelDir, '..', '..'), committedAsset),
        sha256: builtSha,
        bytes: built.length,
        esbuild: esbuildVersion,
        sourceSha,
    }, null, 2));
}
