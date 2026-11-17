import 'dart:io';

import 'package:neug/neug.dart';

Future<void> main(List<String> arguments) async {
  final path = arguments.isEmpty ? ':memory:' : arguments.single;
  final database = await NeugDatabase.open(path);
  try {
    await database.query(
      'CREATE NODE TABLE IF NOT EXISTS Person(id INT64, name STRING, PRIMARY KEY(id));',
    );
    await database.transaction((transaction) async {
      await transaction.query(
        'MERGE (p:Person {id:\$id}) SET p.name=\$name;',
        parameters: {'id': 1, 'name': "\u4e2d\u6587 O'Connor"},
      );
    });
    final result = await database.query(
      'MATCH (p:Person {id:\$id}) RETURN p.id,p.name;',
      parameters: {'id': 1},
    );
    stdout.writeln(result.rows);
  } finally {
    await database.close();
  }
}
