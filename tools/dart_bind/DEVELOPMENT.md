This guide is for NeuG Dart SDK maintainers. See the [README](README.md) for basic application usage. Validate the SDK on the host before preparing mobile native libraries, and regenerate the Dart bindings whenever C API declarations change.

First, prepare a working NeuG library for macOS or Linux. Host-side validation means running SDK tests on the development computer, not in a mobile emulator. macOS has been validated; Linux execution has not yet been tested.

Install Dart 3.10 or later and the dependencies required to build NeuG C++. From the NeuG repository root, run:

```sh
cmake -S . -B build \
  -DNEUG_LITE=ON \
  -DBUILD_COMPILER=ON \
  -DBUILD_PYTHON=OFF \
  -DWITH_MIMALLOC=OFF
cmake --build build --target neug --parallel 2
```

This builds the Lite engine and C API in the shared root `build/` directory. `BUILD_COMPILER=ON` retains query parsing and compilation, `BUILD_PYTHON=OFF` disables Python bindings, and `WITH_MIMALLOC=OFF` uses the system allocator.

Then install Dart dependencies and run the tests and example:

```sh
cd tools/dart_bind
dart pub get
dart test
dart run example/main.dart
```

The example uses a temporary database by default and prints a row containing ID `1` and a name with Unicode characters and an apostrophe. Supply a directory to test persistence and reopening:

```sh
dart run example/main.dart /tmp/neug-dart-demo
```

The SDK first looks for the native library under `native/<target>/`. For macOS / Linux host development with a matching operating system and CPU architecture, it falls back to the repository's `build/src/libneug.dylib` or `build/src/libneug.so` if the staged library is absent. If you previously staged a library manually, update that copy after rebuilding.

After host tests pass, prepare mobile libraries. The Android entry point is `scripts/build_android.sh` at the repository root. It prepares host protoc, cross-compiles the Lite core and C API, and produces `libneug.so` plus a device test executable. The C++ standard library is linked into `libneug.so`; no separate `libc++_shared.so` is needed. See the [Android build guide](../../scripts/README.android.md) for prerequisites, artifacts, and device checks. The iOS build workflow remains to be implemented.

The Android script automatically copies the validated library into `native/android_arm64/` (`native/android_x64/` for x86_64) and updates the packaging manifest. There is no need to stage it manually when using that script. Device execution still requires testing.

**The staging tool below consumes existing binaries; it does not compile them.** Use it for iOS, custom builds, or manual updates.

From the SDK directory, replace the paths below with your artifacts:

```sh
python3 tool/stage_library.py android_arm64 /path/to/android/libneug.so
python3 tool/stage_library.py ios_arm64_device /path/to/iphoneos/libneug.dylib
python3 tool/stage_library.py ios_arm64_simulator /path/to/iphonesimulator/libneug.dylib
```

The target name determines the destination directory. Even when targets share the ARM64 instruction set, different operating systems and device / simulator environments require separate libraries.

| Target | Use |
| --- | --- |
| `android_arm64` | ARM64 Android device or emulator |
| `android_x64` | x86_64 Android emulator |
| `ios_arm64_device` | ARM64 iPhone / iPad |
| `ios_arm64_simulator` | ARM64 iOS simulator |
| `ios_x64_simulator` | x86_64 iOS simulator |

Host development also supports the directory names `macos_arm64`, `macos_x64`, `linux_arm64`, and `linux_x64`. These names describe library selection support, not proof that every target has been built or validated.

The staging tool copies files into `native/<target>/` and generates `libraries.json`, listing the libraries to bundle. Standard Android builds need only `libneug.so`. If you previously staged a shared C++ runtime build, rerun the tool to update the manifest; files outside the new manifest are not bundled. For other platforms or custom builds that require additional non-system shared libraries, append their paths to the command.

Dependency names and loader paths must be configured correctly during native compilation. The staging tool checks file existence, suffixes, and duplicate names; it does not verify that a binary actually matches the selected target.

When an application is built, `hook/build.dart` runs automatically to select and bundle libraries for the target. This is a build hook: a script invoked as part of the build. Applications do not need manual library loading or a Kotlin / JNI or Swift wrapper for database calls.

For host debugging, an application's `pubspec.yaml` can override library selection. Relative paths are resolved from the directory containing that pubspec:

```yaml
hooks:
  user_defines:
    neug:
      library: /absolute/path/to/libneug.dylib
```

Use `native/<target>/` for multi-platform builds. After changing the library selection location, clear the application's build cache before rebuilding.

The following input, output, and resource-management rules apply when integrating or troubleshooting the SDK.

Parameters use `Map<String, Object?>`, with names that omit `$`. Supported values are null, bool, String, int, finite double, List, maps with string keys, and BigInt within the 64-bit range. BigInt represents integers beyond the usual signed range; the accepted overall range is `-2^63` through `2^64 - 1`.

The SDK snapshots parameters when a query is called. Later changes to the original list or map do not affect that query. NaN, infinity, cyclic references, out-of-range integers, and unsupported objects cause `ArgumentError`. Pass dates as millisecond counts or strings as required by the query. The engine infers parameter types, so a JSON-encodable value must still match the query's expected type.

`query()` returns `NeugResult` with `columns` and `rows`. Columns provide names and `NeugType` values; rows contain the data. Empty results retain column metadata. Results are copied into Dart memory, are read-only, and remain valid after the database closes.

| NeuG result type | Dart value |
| --- | --- |
| NULL, BOOL, STRING | null, bool, String |
| Signed integers, UINT32 | int |
| UINT64 | int within the signed range; otherwise BigInt |
| FLOAT, DOUBLE | double; results may contain NaN or infinity |
| DATE, TIMESTAMP | int milliseconds since 1970-01-01 00:00:00 UTC; convert to DateTime as needed |
| INTERVAL | String provided by the engine |
| LIST, TUPLE | Read-only List |
| STRUCT, NODE, RELATIONSHIP, PATH, OBJECT | Read-only Map, with nested values converted using the same rules |

Graph results preserve C API fields: nodes include `_ID` and `_LABEL`; relationships also include `_SRC_ID` and `_DST_ID`; paths include `nodes`, `rels`, and `length`. Do not use internal IDs as persistent business keys. The SDK currently materializes complete results; use LIMIT to bound large queries.

Operations on a database execute sequentially. During a transaction, ordinary queries from other tasks wait for the entire transaction. Use `tx` inside the callback and await every operation. Do not retain `tx` for use after the callback. If rollback succeeds, the original application exception and stack are rethrown. If rollback also fails, `NeugTransactionException` retains both errors.

`close()` waits for queued operations and rejects new queries. If closing fails while the underlying database remains open, resolve the failure and retry. Repeated close calls are safe after successful closure. Applications must explicitly await close rather than relying on garbage collection or process exit.

When C API function declarations change, regenerate the Dart bindings. `lib/src/bindings_generated.dart` is generated from `include/neug/c/neug.h` and describes C function names, arguments, and return types to Dart. Update the header and regenerate instead of editing the generated file manually.

Generation requires libclang, the compiler library used to read C headers. From the SDK directory, run:

```sh
dart run tool/generate_bindings.dart
dart format lib hook tool test example
dart analyze
dart test
```

The SDK is currently consumed from repository source and is not published to pub.dev. `native/`, build caches, and the dependency lockfile are excluded from Git. Maintainers must provide matching native libraries with the SDK when distributing it.
