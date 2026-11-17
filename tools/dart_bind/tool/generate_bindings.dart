import 'dart:io';

import 'package:ffigen/ffigen.dart';

Future<void> main() async {
  final package = Platform.script.resolve('../');
  final include = package.resolve('../../include/');
  final header = include.resolve('neug/c/neug.h');
  await FfiGenerator(
    input: Input(
      entryPoints: [header],
      include: (uri) => uri == header,
      compilerOptions: ['-I${include.toFilePath()}'],
    ),
    output: Output(
      dart: DartOutput(
        path: package.resolve('lib/src/bindings_generated.dart'),
      ),
      preamble:
          '// Generated from include/neug/c/neug.h. Do not edit manually.',
    ),
    visitors: [
      Visitor(
        func: (node) => node.isIncluded = node.name.startsWith('neug_'),
        struct: (node) => node.isIncluded = true,
        unnamedEnumConstant: (node) =>
            node.isIncluded = node.name.startsWith('NEUG_'),
        macroConstant: (node) =>
            node.isIncluded = node.name == 'NEUG_C_API_VERSION',
      ),
    ],
  ).generate();
}
