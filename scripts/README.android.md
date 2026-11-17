This guide describes building NeuG Lite for Android on macOS or Linux x86_64. The entry point is `scripts/build_android.sh`. It produces a native library and a device test executable, then automatically stages the library in the Dart SDK after validation. It does not build an APK, install tools, or modify Aves.

On 2026-11-13, the `arm64-v8a`, API 24 build with a statically linked C++ standard library was cross-compiled on macOS ARM64 using NDK r28c. The resulting library exports only the 32 C API functions and does not depend on `libc++_shared.so`. The pure C test executable linked successfully, and the library passed the 16 KB load-segment alignment check. The complete script, from host protoc compilation through automatic Dart SDK staging, ran successfully. The SDK copy matched the build artifact, with only libneug.so in the packaging manifest. Host C API tests covered recovery after query errors, reads and writes, transactions, and close/reopen; the earlier glob-matching regression test also passed. Android device, emulator, and APK execution have not been validated. Linux hosts, x86_64 targets, and iOS were not part of that validation.

Prerequisites are CMake, a host C/C++ compiler, make, Python 3, the repository's third-party sources, and the Android NDK. Python runs only on the build host to stage artifacts; it is not bundled into the Android library. Use NDK r28c (28.2.13676358) to match Aves. Linux hosts also need `lscpu`. The NDK directory must contain `build/cmake/android.toolchain.cmake`.

From the NeuG root, run:

```bash
export ANDROID_NDK_HOME=/path/to/android-ndk-r28c
bash scripts/build_android.sh
```

The default target is Android ARM64 with minimum API level 24. Set `ANDROID_ABI=x86_64` to build an x86_64 library. Aves China currently packages only ARM64, so an x86_64 library is not a direct replacement.

The script performs these steps:

1. Configure a host build in `build/host-protoc/` and build only `protoc` and its dependencies. This code generator runs on the development computer.
2. Configure an Android build in `build/android-arm64/`, generate C++ sources using host `protoc`, and compile NeuG and its dependencies using the NDK.
3. Check exports and dependencies, link the device test executable, stage the packaged library in `tools/dart_bind/native/android_arm64/`, and update `libraries.json`. Application builds read the library from this location without a manual copy.

The Android configuration retains the query compiler, C API, storage, and transactions. It explicitly disables Python / Node.js bindings, the HTTP server, extensions, mimalloc, examples, and the test suite. It does not change ordinary Lite build defaults or remove protobuf.

The script uses `ANDROID_STL=c++_static` to incorporate the required C++ standard library code into `libneug.so`, leaving one NeuG library to distribute. Android Lite exports only the C API functions listed in `src/c_api/android.exports.map`. Internal C++ and standard-library symbols remain private to avoid conflicts with other native libraries in the application. Update this manifest when adding or removing C API functions. Desktop export rules are unchanged.

If a host protoc matching the repository's protobuf version is already available, skip the first step:

```bash
NEUG_HOST_PROTOC="$PWD/build/third_party/protobuf/protoc" \
  bash scripts/build_android.sh
```

`NEUG_HOST_PROTOC` must be an absolute path. CMake runs its `--version` and rejects tools that cannot execute on the host or have the wrong version. Custom cross-compilation commands can also pass `-DNEUG_HOST_PROTOC=/path/to/protoc` without using the script. Ordinary host builds without this option continue to use their own `protobuf::protoc` target.

The script defaults to two parallel build jobs. `BUILD_JOBS` can change this limit, capped at the host's physical core count. Repeated runs build incrementally. Do not share a CMake build directory between host and Android builds. Use a clean Android build directory when changing the NDK or minimum API level.

Main outputs are listed below. For x86_64, the Android build directory is `android-x64`:

```text
build/host-protoc/
  configure.log                 Host configuration log
  build.log                     Host protoc build log
  third_party/protobuf/protoc    Host tool; not bundled in the APK
build/android-arm64/
  configure.log                 Android configuration log
  build.log                     Android build log
  src/libneug.so                 Original library artifact
  dist/
    libneug.so                  Stripped Android library for applications
    c_api_smoke                 Pure C device test; not bundled in the APK
    dependencies.txt            ELF dynamic dependency list
    symbols.txt                 Exported symbol list
tools/dart_bind/native/android_arm64/
  libneug.so                    Automatically updated application library
  libraries.json                Packaging manifest containing only libneug.so
```

The script requires exports to match the C API manifest exactly and permits only Android system shared-library dependencies. A dependency on `libc++_shared.so` causes failure. Passing these checks and linking successfully does not prove Android runtime behavior. `src/libneug.so` retains debug information for diagnosis; `dist/libneug.so` strips debug information and symbols not required at runtime to reduce package size, without removing C API exports.

After a successful script run, the SDK library and manifest are already updated. To stage a library built another way, run:

```bash
python3 tools/dart_bind/tool/stage_library.py android_arm64 \
  build/android-arm64/dist/libneug.so
```

The staging tool copies the file into `tools/dart_bind/native/android_arm64/` and writes `libraries.json` containing only `libneug.so`. The build script calls it automatically, replacing the previous library and manifest. Files not listed in the new manifest are not packaged. The script also removes a stale `libc++_shared.so` from `dist/`. Other Aves plugins may still require their own shared C++ runtime; do not remove those dependencies.

Validate device execution in two stages.

First, test the C API independently on an ARM64 Android device or emulator using `adb` from the Android SDK. Replace `<device-serial>` with a serial from `adb devices -l`. Use a new, test-only database directory for each run:

```bash
adb -s <device-serial> shell mkdir -p /data/local/tmp/neug-check
adb -s <device-serial> push build/android-arm64/dist/libneug.so /data/local/tmp/neug-check/
adb -s <device-serial> push build/android-arm64/dist/c_api_smoke /data/local/tmp/neug-check/
adb -s <device-serial> shell chmod 755 /data/local/tmp/neug-check/c_api_smoke
adb -s <device-serial> shell 'LD_LIBRARY_PATH=/data/local/tmp/neug-check /data/local/tmp/neug-check/c_api_smoke /data/local/tmp/neug-check/db-run-1'
```

Exit code 0 indicates success. The executable checks database opening, query-error recovery, JSON parameters, scalar result reading, and cleanup through the C API. It does not depend on Flutter. Writes, transactions, and persistence still require the application-level checks below.

Then build Aves and validate the full call path:

```bash
cd ../aves
./flutterw pub get
./flutterw build apk --debug --flavor china -t lib/main_china.dart --target-platform android-arm64
```

The APK is written to `aves/build/app/outputs/flutter-apk/app-china-debug.apk`. On the device, also check:

- Native library and Dart FFI loading, and photo, person, and tag operations.
- Data recovery after normal close/reopen and forced process termination. Compatibility with prototype database files requires separate validation.
- Long-running queries, concurrent operations, and application backgrounding.
- Loading and storage behavior across supported Android versions and page sizes, including devices with 16 KB memory pages.

These commands are validation entry points, not substitutes for actual device test results. iOS builds are outside the scope of the Android script.
