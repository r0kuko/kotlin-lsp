#!/usr/bin/env bash
# Build a portable, BMI2-free librocksdbjni-win64.dll using a Linux + MinGW-w64
# cross-toolchain inside Docker. The resulting DLL is intended for the
# `native-overrides/win32-x64/rocksdbjni/` slot consumed by `unpack-server.js`.
#
# Why: the JetBrains language-server bundle ships a RocksDB JNI DLL compiled
# with BMI2 (bzhi/pdep/pext/mulx), which crashes with EXCEPTION_ILLEGAL_INSTRUCTION
# on Intel Ivy Bridge and older CPUs. -DPORTABLE=ON disables CPU-specific
# instruction selection. See `kotlin-vscode/native-overrides/README.md`.
#
# Usage:
#   scripts/build-portable-rocksdbjni-win64.sh [--rocksdb-version 9.4.0]
#
# Output:
#   kotlin-vscode/native-overrides/win32-x64/rocksdbjni/librocksdbjni-win64.dll
#
# Requirements:
#   - docker (Linux containers)
#   - ~10 minutes for the first build (subsequent builds reuse the image cache)

set -euo pipefail

ROCKSDB_VERSION="9.4.0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rocksdb-version) ROCKSDB_VERSION="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_ROOT/kotlin-vscode/native-overrides/win32-x64/rocksdbjni"
IMAGE_TAG="kotlin-lsp/rocksdbjni-portable:${ROCKSDB_VERSION}"

mkdir -p "$OUT_DIR"

BUILD_CTX="$(mktemp -d)"
trap 'rm -rf "$BUILD_CTX"' EXIT

cat > "$BUILD_CTX/Dockerfile" <<EOF
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
ARG ROCKSDB_VERSION=${ROCKSDB_VERSION}
RUN apt-get update && apt-get install -y --no-install-recommends \\
      git ca-certificates cmake make ninja-build \\
      gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 binutils-mingw-w64-x86-64 \\
      openjdk-21-jdk-headless \\
 && rm -rf /var/lib/apt/lists/*
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

WORKDIR /build
RUN git clone --depth=1 --branch "v\${ROCKSDB_VERSION}" \\
      https://github.com/facebook/rocksdb.git rocksdb \\
 && mkdir -p \$JAVA_HOME/include/win32 \\
 && cp \$JAVA_HOME/include/linux/jni_md.h \$JAVA_HOME/include/win32/jni_md.h

RUN cat > /build/mingw64.cmake <<'TC'
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER x86_64-w64-mingw32-gcc-posix)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++-posix)
set(CMAKE_RC_COMPILER x86_64-w64-mingw32-windres)
set(CMAKE_AR x86_64-w64-mingw32-ar)
set(CMAKE_RANLIB x86_64-w64-mingw32-ranlib)
set(CMAKE_FIND_ROOT_PATH /usr/x86_64-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
TC

WORKDIR /build/rocksdb
RUN cmake -B build -G Ninja \\
      -DCMAKE_TOOLCHAIN_FILE=/build/mingw64.cmake \\
      -DCMAKE_BUILD_TYPE=Release \\
      -DPORTABLE=ON \\
      -DFORCE_SSE42=OFF \\
      -DWITH_JNI=ON \\
      -DJAVA_HOME=\$JAVA_HOME \\
      -DJAVA_INCLUDE_PATH=\$JAVA_HOME/include \\
      -DJAVA_INCLUDE_PATH2=\$JAVA_HOME/include/win32 \\
      -DJAVA_JVM_LIBRARY=\$JAVA_HOME/lib/server/libjvm.so \\
 && ninja -C build rocksdbjni -j"\$(nproc)"

# CMake on MinGW emits only a static lib for rocksdbjni. Link it into a DLL
# with statically-embedded MinGW runtime so the result has no extra deps.
RUN set -eux; \\
    DEF=/tmp/rocksdbjni.def; \\
    echo 'LIBRARY librocksdbjni-win64.dll' > \$DEF; \\
    echo 'EXPORTS' >> \$DEF; \\
    nm /build/rocksdb/build/java/liblibrocksdbjni-win64.a 2>/dev/null \\
      | grep ' T Java_org_rocksdb' \\
      | awk '{print \$3}' \\
      | sort >> \$DEF; \\
    EXPORTS=\$(grep -c '^Java_' \$DEF); \\
    echo "Exporting \$EXPORTS JNI symbols"; \\
    test "\$EXPORTS" -gt 100; \\
    x86_64-w64-mingw32-dlltool \\
      --dllname librocksdbjni-win64.dll \\
      --def \$DEF \\
      --output-exp /tmp/rocksdbjni.exp; \\
    mkdir -p /out; \\
    x86_64-w64-mingw32-g++-posix -shared \\
      -o /out/librocksdbjni-win64.dll /tmp/rocksdbjni.exp \\
      -Wl,--whole-archive \\
        /build/rocksdb/build/java/liblibrocksdbjni-win64.a \\
        /build/rocksdb/build/librocksdb.a \\
      -Wl,--no-whole-archive \\
      -static \\
      -lshlwapi -lrpcrt4 -lws2_32 -ladvapi32 -lkernel32 -luser32 -lwinpthread; \\
    BMI2=\$(x86_64-w64-mingw32-objdump -d /out/librocksdbjni-win64.dll \\
            | grep -cE 'bzhi|mulx|pdep|pext' || true); \\
    echo "BMI2 instruction count: \$BMI2"; \\
    test "\$BMI2" -eq 0
EOF

echo ">>> Building image $IMAGE_TAG (first build ~10min, cached thereafter)..."
docker build --tag "$IMAGE_TAG" "$BUILD_CTX"

echo ">>> Extracting DLL to $OUT_DIR..."
CID="$(docker create "$IMAGE_TAG")"
trap 'docker rm -f "$CID" >/dev/null 2>&1; rm -rf "$BUILD_CTX"' EXIT
docker cp "$CID:/out/librocksdbjni-win64.dll" "$OUT_DIR/librocksdbjni-win64.dll"

SIZE=$(stat -c%s "$OUT_DIR/librocksdbjni-win64.dll" 2>/dev/null \
       || stat -f%z "$OUT_DIR/librocksdbjni-win64.dll")
echo ">>> Done: $OUT_DIR/librocksdbjni-win64.dll ($SIZE bytes)"
echo ">>> Next: re-run \`npm run unpack-server\` (or \`vsce package\`) so the"
echo "    overlay is applied to server/lib/rocksdbjni/."
