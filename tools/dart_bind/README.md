This directory contains the NeuG Dart SDK, the database interface for Dart and Flutter applications. Applications can open databases, execute queries, and read results without managing C pointers or native memory themselves.

The call path is **application → Dart SDK → C API → NeuG database engine**. Flutter handles the UI, NeuG handles queries and storage, and this package connects them.

**The Dart interface is implemented and has been tested on macOS.** The Android ARM64 native library has been cross-compiled; see the [Android build guide](../../scripts/README.android.md). APK, emulator, and physical-device execution have not yet been validated. iOS can share the Dart code, but its native library build remains to be implemented. End-to-end mobile SDK validation is not complete.

Integration requires two parts:

- **Dart interface code**: this package. Applications use `NeugDatabase` to access the database.
- **NeuG native library**: the compiled C++ database engine. Android uses `libneug.so` with the C++ standard library linked into it, so no separate `libc++_shared.so` is required. iOS uses `libneug.dylib`. SDK maintainers must provide the appropriate files to bundle with the application.

This complete Dart example opens a temporary database, creates a table, inserts a record, and reads it back:

```dart
import 'package:neug/neug.dart';

Future<void> main() async {
  final db = await NeugDatabase.open(':memory:');
  try {
    await db.query(
      'CREATE NODE TABLE Person('
      'id INT64, name STRING, PRIMARY KEY(id));',
    );
    await db.query(
      r'CREATE (:Person {id: $id, name: $name});',
      parameters: {'id': 1, 'name': 'Alice'},
    );

    final result = await db.query(
      r'MATCH (p:Person {id: $id}) RETURN p.id, p.name;',
      parameters: {'id': 1},
    );
    print(result.rows); // [[1, Alice]]
  } finally {
    await db.close();
  }
}
```

The methods have distinct responsibilities:

- `open()` opens a database. `:memory:` selects a temporary database; pass a directory path to retain data. On mobile devices, use an application-private directory that the application can write to.
- `query()` handles reads, schema changes, and writes. Keep the result for reads; otherwise await the call and discard the result. Each element of `result.rows` is a list representing one row, so `[[1, Alice]]` contains one row with two columns.
- `close()` closes the database and releases resources. Calling it in `finally` also handles failures in earlier operations.

`$id` and `$name` are query placeholders supplied through `parameters`. The `r` prefix preserves those strings for NeuG rather than letting Dart interpolate them. The SDK encodes the parameter map as JSON for the C API.

Each database operation is awaited before proceeding. The SDK runs database work in the background so queries do not occupy the Flutter UI isolate.

Failed queries throw `NeugException`, whose `code` is the error code and `message` describes the failure. The example propagates exceptions to its caller while still closing the database in `finally`.

Use a transaction when multiple operations must succeed together. The SDK commits after a successful callback and rolls back if the callback throws:

```dart
await db.transaction((tx) async {
  await tx.query('CREATE (:Person {id: 2, name: "Bob"});');
  await tx.query('CREATE (:Person {id: 3, name: "Carol"});');
});
```

Run this before closing the database and after creating the table. Use the supplied `tx.query()` inside the callback. Nested transactions on the same database are unsupported.

The database operation interface consists of `open()`, `query()`, `transaction()`, and `close()`. The read-only `isClosed` property exposes the close state. If close fails and this property remains `false`, resolve the failure and retry closing.

Add the SDK to the Flutter application's `pubspec.yaml`, adjusting the path to match your directory layout:

```yaml
dependencies:
  neug:
    path: ../neug/tools/dart_bind
```

Run `flutter pub get` in the application directory, then import `package:neug/neug.dart`. The SDK requires Dart 3.10 or later. Flutter applications require Flutter 3.38 or later for automatic native-library bundling.

**Running on a mobile device also requires a NeuG native library for that target.** A macOS library supports host-side testing only. Android requires an Android library; iOS devices and simulators need separate builds. The Android build script automatically stages the validated library in `native/android_arm64/`, and the SDK bundles it when building the application. No manual copy is required before application builds and device validation.

See the [development and build guide](DEVELOPMENT.md) to run examples on the host or continue Android / iOS integration. It also documents input and output types, build commands, and C binding maintenance.
