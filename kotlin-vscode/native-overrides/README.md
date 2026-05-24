# Native overrides

This directory is consumed by [`unpack-server.js`](../unpack-server.js) **after**
the upstream JetBrains language-server bundle (`LSP_ZIP_PATH`) is extracted
into `kotlin-vscode/server/`. Any file placed here is copied on top of the
corresponding file under `server/lib/`, replacing the bundled binary.

## Layout

```
native-overrides/
  common/                            # always applied
    <relative-path-under-server/lib>
  <vsce-target>/                     # applied when VSCE_TARGET matches
    <relative-path-under-server/lib>
```

`VSCE_TARGET` is the vsce platform identifier set by
[`buildExtension.sh`](../buildExtension.sh) — `win32-x64`, `linux-x64`,
`linux-arm64`, `darwin-x64`, `darwin-arm64`, …

The target file **must already exist** in the bundle; missing targets are
skipped with a warning to prevent typos from silently shipping orphan files.

`KOTLIN_LSP_NATIVE_OVERRIDES=<abs-path>` overrides the search root, useful
for one-off local rebuilds without touching the source tree.

The directory is excluded from the packaged `.vsix` by the default-deny
[`.vscodeignore`](../.vscodeignore), since its contents have already been
merged into `server/lib/` by the time `vsce package` runs.

## Motivating use case: RocksDB BMI2 crash on Ivy Bridge

The bundled `lib/rocksdbjni/librocksdbjni-win64.dll` (RocksDB 9.x JNI) is
built with BMI2 (`bzhi` / `pdep` / `pext` / `mulx`). On Intel Ivy Bridge
(Xeon E5 v2 and earlier) — which supports BMI1 but not BMI2 — loading the
DLL crashes the JVM with `EXCEPTION_ILLEGAL_INSTRUCTION` and the LSP exits
silently before announcing its port. Symptom in the VS Code output channel:

```
Failed to connect to LSP server on port NNNNN: AggregateError
```

The fix is to drop a portable rebuild at:

```
native-overrides/win32-x64/rocksdbjni/librocksdbjni-win64.dll
```

Build it via [`scripts/build-portable-rocksdbjni-win64.sh`](../../scripts/build-portable-rocksdbjni-win64.sh)
(requires Docker; cross-compiles with MinGW-w64 and `-DPORTABLE=ON`, statically
links the MinGW runtime, and verifies the result is BMI2-free).

## Caveats

- `unpack-server` runs during `npm run vscode:prepublish`. If you change a
  file under `native-overrides/` you must rerun `vsce package` (or
  `npm run unpack-server`) for the change to land in `server/lib/`.
- Stale RocksDB index files written by the BMI2-tainted DLL may need to be
  cleared after swap-in: `%APPDATA%\JetBrains\analyzer` on Windows,
  `~/Library/Caches/JetBrains/analyzer` on macOS,
  `~/.cache/JetBrains/analyzer` on Linux.
