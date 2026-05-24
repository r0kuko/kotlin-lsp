#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const zip = process.env.LSP_ZIP_PATH;
if (!zip) {
  console.error('Error: LSP_ZIP_PATH is not set');
  process.exit(1);
}
if (!fs.existsSync(zip)) {
  console.error(`Error: LSP zip not found: ${zip}`);
  process.exit(1);
}

const serverDir = path.resolve(__dirname, 'server');
const tmpDir = path.resolve(__dirname, 'server.tmp');
const isWin = process.platform === 'win32';
const lower = zip.toLowerCase();

// On Windows pin to bsdtar shipped in System32 — Git Bash's GNU tar appears
// first on PATH in many dev shells and rejects `C:\…` archive paths with
// "Cannot connect to C: resolve failed".
const tarCmd = isWin
  ? path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'tar.exe')
  : 'tar';

function run(cmd, args) {
  const r = spawnSync(cmd, args, { stdio: 'inherit' });
  if (r.error) {
    console.error(r.error.message);
    process.exit(1);
  }
  if (r.status !== 0) process.exit(r.status ?? 1);
}

fs.rmSync(serverDir, { recursive: true, force: true });
fs.rmSync(tmpDir, { recursive: true, force: true });

if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
  fs.mkdirSync(serverDir, { recursive: true });
  run(tarCmd, ['-xzf', zip, '--strip-components=1', '-C', serverDir]);
} else if (lower.endsWith('.zip')) {
  fs.mkdirSync(serverDir, { recursive: true });
  if (isWin) run(tarCmd, ['-xf', zip, '-C', serverDir]);
  else run('unzip', ['-q', '-o', '--', zip, '-d', serverDir]);
} else if (lower.endsWith('.sit')) {
  fs.mkdirSync(tmpDir, { recursive: true });
  if (isWin) run(tarCmd, ['-xf', zip, '-C', tmpDir]);
  else run('unzip', ['-q', '-o', '--', zip, '-d', tmpDir]);

  // Promote tmp contents into server/. If the archive has a single top-level
  // directory, strip that level (matches the original `mv server.tmp/* server`
  // behavior after the preceding `rmdir server`).
  const entries = fs.readdirSync(tmpDir);
  if (entries.length === 1 && fs.statSync(path.join(tmpDir, entries[0])).isDirectory()) {
    fs.renameSync(path.join(tmpDir, entries[0]), serverDir);
  } else {
    fs.mkdirSync(serverDir, { recursive: true });
    for (const name of entries) {
      fs.renameSync(path.join(tmpDir, name), path.join(serverDir, name));
    }
  }
  fs.rmSync(tmpDir, { recursive: true, force: true });
} else {
  console.error(`Unsupported archive type: ${zip}`);
  process.exit(1);
}

const libDir = path.join(serverDir, 'lib');
if (!fs.existsSync(libDir) || !fs.statSync(libDir).isDirectory()) {
  console.error(`Error: unpacked LSP is missing 'lib' directory: ${libDir}`);
  process.exit(1);
}

if (fs.existsSync(path.join(libDir, '..', 'EULA.txt'))) {
  console.log("##teamcity[addBuildTag 'EULA']");
}

// Native overlay: replace selected files under `server/lib/` with sideloaded
// portable variants. Use case: ship rebuilt versions of native libraries that
// the upstream JetBrains bundle hard-codes with CPU-specific instructions
// (e.g. RocksDB's `librocksdbjni-win64.dll` compiled with BMI2, which crashes
// with EXCEPTION_ILLEGAL_INSTRUCTION on Ivy Bridge and older CPUs).
//
// Layout: kotlin-vscode/native-overrides/<vsce-target>/<path-under-server/lib>
//   e.g. native-overrides/win32-x64/rocksdbjni/librocksdbjni-win64.dll
//
// Activation:
//   - VSCE_TARGET env var (set by buildExtension.sh) selects the platform
//     subdirectory. When unset (dev builds), only `common/` is overlaid.
//   - Override the search root via KOTLIN_LSP_NATIVE_OVERRIDES (absolute path).
//
// No-op when the overrides directory does not exist, so this is safe to leave
// in place unconditionally.
function applyNativeOverrides() {
  const root = process.env.KOTLIN_LSP_NATIVE_OVERRIDES
    || path.resolve(__dirname, 'native-overrides');
  if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) return;

  const platforms = ['common'];
  if (process.env.VSCE_TARGET) platforms.push(process.env.VSCE_TARGET);

  let replaced = 0;
  for (const platform of platforms) {
    const src = path.join(root, platform);
    if (!fs.existsSync(src) || !fs.statSync(src).isDirectory()) continue;
    replaced += overlayDir(src, libDir);
  }
  if (replaced > 0) {
    console.log(`[unpack-server] native-overrides: replaced ${replaced} file(s) under ${libDir}`);
  }
}

function overlayDir(srcDir, dstDir) {
  let count = 0;
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const srcPath = path.join(srcDir, entry.name);
    const dstPath = path.join(dstDir, entry.name);
    if (entry.isDirectory()) {
      fs.mkdirSync(dstPath, { recursive: true });
      count += overlayDir(srcPath, dstPath);
    } else if (entry.isFile()) {
      if (!fs.existsSync(dstPath)) {
        console.warn(`[unpack-server] native-overrides: target missing, skipping ${dstPath}`);
        continue;
      }
      fs.copyFileSync(srcPath, dstPath);
      count++;
    }
  }
  return count;
}

applyNativeOverrides();
