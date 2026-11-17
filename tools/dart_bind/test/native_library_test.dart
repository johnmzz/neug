import 'dart:io';

import 'package:test/test.dart';

import '../hook/native_library.dart';

void main() {
  test('select separate device, simulator, and Android libs', () async {
    final directory = await Directory.systemTemp.createTemp('neug-assets-');
    addTearDown(() => directory.delete(recursive: true));
    Future<void> prepare(String target, String name, String contents) async {
      final file = File.fromUri(directory.uri.resolve('native/$target/$name'));
      await file.parent.create(recursive: true);
      await file.writeAsString(contents);
    }

    await prepare('android_arm64', 'libneug.so', 'android');
    await prepare('ios_arm64_device', 'libneug.dylib', 'device');
    await prepare('ios_arm64_simulator', 'libneug.dylib', 'simulator');
    Uri select(
      String os, {
      String architecture = 'arm64',
      bool? simulator,
      Uri? configured,
    }) => selectNativeLibrary(
      packageRoot: directory.uri,
      os: os,
      architecture: architecture,
      hostAbi: 'macos_arm64',
      simulator: simulator,
      configured: configured,
    );
    expect(File.fromUri(select('android')).readAsStringSync(), 'android');
    expect(
      File.fromUri(select('ios', simulator: false)).readAsStringSync(),
      'device',
    );
    expect(
      File.fromUri(select('ios', simulator: true)).readAsStringSync(),
      'simulator',
    );
    expect(() => select('android', architecture: 'x64'), throwsStateError);
    expect(() => select('ios'), throwsArgumentError);
    expect(() => select('windows'), throwsUnsupportedError);
    expect(
      () => select('android', configured: directory.uri.resolve('missing.so')),
      throwsStateError,
    );
  });
}
