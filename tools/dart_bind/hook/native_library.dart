import 'dart:io';

/// Distinguish operating systems, CPU architectures, and iOS devices from
/// simulators.
String nativeTarget(String os, String architecture, {bool? simulator}) {
  if (!{'android', 'ios', 'macos', 'linux'}.contains(os)) {
    throw UnsupportedError(
      'The NeuG Dart SDK does not support native library packaging for $os',
    );
  }
  if (os == 'ios') {
    if (simulator == null) {
      throw ArgumentError(
        'Specify whether the iOS target is a device or simulator',
      );
    }
    return '${os}_${architecture}_${simulator ? 'simulator' : 'device'}';
  }
  return '${os}_$architecture';
}

String nativeFilename(String os) =>
    os == 'macos' || os == 'ios' ? 'libneug.dylib' : 'libneug.so';

Uri selectNativeLibrary({
  required Uri packageRoot,
  required String os,
  required String architecture,
  required String hostAbi,
  bool? simulator,
  Uri? configured,
}) {
  final target = nativeTarget(os, architecture, simulator: simulator);
  final filename = nativeFilename(os);
  var library = configured ?? packageRoot.resolve('native/$target/$filename');
  if (configured == null &&
      !File.fromUri(library).existsSync() &&
      (os == 'macos' || os == 'linux') &&
      hostAbi == '${os}_$architecture') {
    final repository = packageRoot.resolve('../../');
    if (File.fromUri(
      repository.resolve('include/neug/c/neug.h'),
    ).existsSync()) {
      library = repository.resolve('build/src/$filename');
    }
  }
  if (!File.fromUri(library).existsSync()) {
    throw StateError(
      'NeuG native library for $target was not found: ${library.toFilePath()}. '
      'Build the target library and stage it in native/$target/ using python3 tool/stage_library.py; '
      'alternatively, set hooks.user_defines.neug.library to its path.',
    );
  }
  return library;
}
