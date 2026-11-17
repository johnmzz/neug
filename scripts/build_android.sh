#!/usr/bin/env bash
# Build NeuG Lite for Android and stage it in the Dart SDK; do not install tools or modify Aves.
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: ANDROID_NDK_HOME=/path/to/ndk bash scripts/build_android.sh
Optional environment variables:
  ANDROID_HOME       Search ndk/28.2.13676358 here if no NDK is specified
  ANDROID_ABI        arm64-v8a (default) or x86_64
  ANDROID_PLATFORM   Minimum API level, default 24 (numeric value only)
  NEUG_HOST_PROTOC   Absolute path to host protoc; built from bundled sources if unset
  BUILD_JOBS         Parallel jobs, default 2, capped at the host physical core count
Output: library, dependency list, and symbol list under build/android-<arm64|x64>/dist/.
After validation, update the library and manifest in tools/dart_bind/native/android_<arm64|x64>/.
EOF
  exit 0
fi
[[ $# == 0 ]] || { echo 'Unknown argument; use --help for usage' >&2; exit 1; }
fail() { echo "Error: $*" >&2; exit 1; }
command -v cmake >/dev/null || fail 'Install CMake and add it to PATH'
command -v python3 >/dev/null || fail 'Install Python 3 to stage artifacts in the Dart SDK'
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ndk_root="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_HOME:-}/ndk/28.2.13676358}}"
[[ -f "$ndk_root/build/cmake/android.toolchain.cmake" ]] || fail 'NDK not found; set ANDROID_NDK_HOME'
ndk_root="$(cd "$ndk_root" && pwd)"
case "$(uname -s)" in
  Darwin) host_tag=darwin-x86_64; cores="$(sysctl -n hw.physicalcpu 2>/dev/null || echo 1)" ;;
  Linux)
    [[ "$(uname -m)" == x86_64 ]] || fail 'The official NDK r28c Linux host tools require x86_64'
    command -v lscpu >/dev/null || fail 'Install lscpu (usually provided by util-linux)'
    host_tag=linux-x86_64
    cores="$(lscpu -p=CORE,SOCKET | awk '!/^#/ {print}' | sort -u | wc -l)"
    ;;
  *) fail 'This script supports macOS and Linux build hosts' ;;
esac
jobs="${BUILD_JOBS:-2}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || fail 'BUILD_JOBS must be a positive integer'
(( cores > 0 )) || cores=1
(( jobs <= cores )) || jobs="$cores"
abi="${ANDROID_ABI:-arm64-v8a}"
case "$abi" in
  arm64-v8a) target=arm64; triple=aarch64-linux-android ;;
  x86_64) target=x64; triple=x86_64-linux-android ;;
  *) fail 'ANDROID_ABI must be arm64-v8a or x86_64' ;;
esac
api="${ANDROID_PLATFORM:-24}"
[[ "$api" =~ ^[1-9][0-9]*$ ]] && (( api >= 24 )) || fail 'ANDROID_PLATFORM must be an integer of at least 24'
toolchain="$ndk_root/toolchains/llvm/prebuilt/$host_tag"
[[ -x "$toolchain/bin/clang" ]] || fail "NDK does not contain compiler tools for this host: $host_tag"
build_dir="$repo_root/build/android-$target"
host_dir="$repo_root/build/host-protoc"
mkdir -p "$build_dir"

common=(-DCMAKE_BUILD_TYPE=Release -DNEUG_LITE=ON -DBUILD_COMPILER=ON
  -DBUILD_PYTHON=OFF -DBUILD_NODEJS=OFF -DBUILD_HTTP_SERVER=OFF
  -DBUILD_TEST=OFF -DBUILD_EXAMPLES=OFF -DBUILD_EXECUTABLES=OFF
  -DBUILD_EXTENSIONS= -DNEUG_EXTENSION_CONFIGS= -DWITH_MIMALLOC=OFF
  -DNEUG_NATIVE_ARCH=OFF -DENABLE_BACKTRACES=OFF)
host_protoc="${NEUG_HOST_PROTOC:-}"
if [[ -z "$host_protoc" ]]; then
  mkdir -p "$host_dir"
  # Do not let the host build inherit compiler settings or flags intended for Android.
  env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS \
    cmake -S "$repo_root" -B "$host_dir" "${common[@]}" \
      -DCMAKE_TOOLCHAIN_FILE= -DNEUG_HOST_PROTOC= 2>&1 | tee "$host_dir/configure.log"
  cmake --build "$host_dir" --target protoc --parallel "$jobs" 2>&1 | tee "$host_dir/build.log"
  host_protoc="$host_dir/third_party/protobuf/protoc"
fi
[[ "$host_protoc" == /* && -x "$host_protoc" ]] || fail 'NEUG_HOST_PROTOC must be an absolute path to an executable'

cmake -S "$repo_root" -B "$build_dir" "${common[@]}" \
  -DCMAKE_TOOLCHAIN_FILE="$ndk_root/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$api" \
  -DANDROID_STL=c++_static -DCMAKE_SKIP_RPATH=ON \
  -DNEUG_HOST_PROTOC="$host_protoc" 2>&1 | tee "$build_dir/configure.log"
cmake --build "$build_dir" --target neug --parallel "$jobs" 2>&1 | tee "$build_dir/build.log"

# Record dependencies and symbols for inspection; reject unhandled shared-library dependencies.
library="$build_dir/src/libneug.so"
"$toolchain/bin/llvm-readelf" --dynamic "$library" > "$build_dir/dependencies.txt"
"$toolchain/bin/llvm-nm" --dynamic --defined-only "$library" > "$build_dir/symbols.txt"
# Exports must match the manifest exactly, with no missing C APIs or exposed C++ runtime symbols.
diff -u \
  <(sed -n 's/^[[:space:]]*\(neug_[a-z0-9_]*\);$/\1/p' "$repo_root/src/c_api/android.exports.map" | LC_ALL=C sort) \
  <(awk '{print $NF}' "$build_dir/symbols.txt" | LC_ALL=C sort) \
  || fail "Exported symbols do not match the C API manifest; see $build_dir/symbols.txt"
while IFS= read -r dependency; do
  case "$dependency" in
    libc.so|libm.so|libdl.so|liblog.so|libandroid.so|libz.so) ;;
    *) fail "Unexpected shared dependency: $dependency; see $build_dir/dependencies.txt" ;;
  esac
done < <(sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p' "$build_dir/dependencies.txt")
mkdir -p "$build_dir/dist"
cp "$library" "$build_dir/dist/libneug.so"
# Remove the copy left by earlier shared-runtime builds to avoid accidental packaging.
rm -f "$build_dir/dist/libc++_shared.so"
# Keep debug information in the original artifact; strip nonessential symbols from the packaged copy.
"$toolchain/bin/llvm-strip" --strip-unneeded "$build_dir/dist/libneug.so"
cp "$build_dir/dependencies.txt" "$build_dir/symbols.txt" "$build_dir/dist/"
# Reuse the pure C API test to produce a device executable that can be run through adb.
"$toolchain/bin/clang" --target="$triple$api" --sysroot="$toolchain/sysroot" \
  -std=c11 -fPIE -pie -I"$repo_root/include" "$repo_root/tests/c_api/smoke.c" \
  -L"$build_dir/dist" -lneug -o "$build_dir/dist/c_api_smoke"
python3 "$repo_root/tools/dart_bind/tool/stage_library.py" "android_$target" \
  "$build_dir/dist/libneug.so"
echo "Android $abi build completed: $build_dir/dist"
echo "Dart SDK native library updated: $repo_root/tools/dart_bind/native/android_$target"
echo 'Build validation only; loading, reads, writes, transactions, and persistence still require Android runtime validation.'
