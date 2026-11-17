import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'native_library.dart';

void main(List<String> arguments) async {
  await build(arguments, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final os = code.targetOS.name;
    final architecture = code.targetArchitecture.name;
    final library = selectNativeLibrary(
      packageRoot: input.packageRoot,
      os: os,
      architecture: architecture,
      hostAbi: Abi.current().toString(),
      simulator: code.targetOS == OS.iOS
          ? code.iOS.targetSdk == IOSSdk.iPhoneSimulator
          : null,
      configured: input.userDefines.path('library'),
    );
    output.dependencies.add(library);
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/bindings_generated.dart',
        linkMode: DynamicLoadingBundled(),
        file: library,
      ),
    );

    // Bundle only companion libraries listed in the maintainer manifest.
    final parent = File.fromUri(library).parent;
    final manifest = File.fromUri(parent.uri.resolve('libraries.json'));
    if (!manifest.existsSync()) return;
    output.dependencies.add(manifest.uri);
    final names = (jsonDecode(manifest.readAsStringSync()) as List)
        .cast<String>();
    for (final name in names) {
      if (name == library.pathSegments.last) continue;
      if (name.contains('/') || name.contains('\\') || name == '..') {
        throw StateError('Invalid shared library filename: $name');
      }
      final entry = File.fromUri(parent.uri.resolveUri(Uri(path: name)));
      if (!entry.existsSync()) {
        throw StateError('Missing companion shared library: ${entry.path}');
      }
      output.dependencies.add(entry.uri);
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: 'src/native_dependencies/$name',
          linkMode: DynamicLoadingBundled(),
          file: entry.uri,
        ),
      );
    }
  });
}
