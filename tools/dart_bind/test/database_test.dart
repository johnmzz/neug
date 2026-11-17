import 'dart:async';
import 'dart:io';

import 'package:neug/neug.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String path;
  late NeugDatabase database;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('neug-dart-');
    path = '${directory.path}/db';
    database = await NeugDatabase.open(path);
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<void> contacts() async {
    await database.query(
      'CREATE NODE TABLE Person(id INT64, name STRING, PRIMARY KEY(id));',
    );
    await database.query(
      'CREATE (:Person {id:\$id,name:\$name});',
      parameters: {'id': 1, 'name': 'Alice'},
    );
  }

  Future<String> name() async =>
      (await database.query(
            'MATCH (p:Person {id:1}) RETURN p.name;',
          )).rows.single.single
          as String;

  test('preserve parameters and special text across reopen', () async {
    await contacts();
    const value = "\u4e2d\u6587🙂 O'Connor\\line\nnext\u0000tail";
    await database.query(
      'MATCH (p:Person {id:\$id}) SET p.name=\$name;',
      parameters: {'id': 1, 'name': value},
    );
    expect(await name(), value);
    await database.close();
    database = await NeugDatabase.open(path);
    expect(await name(), value);
  });

  test('convert integer, boolean, floating-point, and NULL values', () async {
    final maximum = (BigInt.one << 64) - BigInt.one;
    final result = await database.query(
      "RETURN CAST(\$signed,'INT64'), CAST(\$unsigned,'UINT64'), "
      "CAST(\$flag,'BOOL'), CAST(\$number,'DOUBLE'), CAST(\$nil,'STRING');",
      parameters: {
        'signed': -9223372036854775808,
        'unsigned': maximum,
        'flag': true,
        'number': 1.25,
        'nil': null,
      },
    );
    expect(result.rows.single, [
      -9223372036854775808,
      maximum,
      true,
      1.25,
      null,
    ]);
    expect(result.columns[1].type, NeugType.uint64);
    expect(result.columns[4].type, NeugType.string);
  });

  test('convert lists, structs, and tuples to read-only values', () async {
    final result = await database.query(
      "RETURN CAST([1,CAST(NULL,'INT64'),3],'INT64[]'), "
      "CAST({name:'Alice',ages:CAST([25,26],'INT64[]')},"
      "'STRUCT(name STRING, ages INT64[])'), [1,'a'];",
    );
    expect(result.rows.single, [
      [1, null, 3],
      {
        'name': 'Alice',
        'ages': [25, 26],
      },
      [1, 'a'],
    ]);
    expect(() => result.rows.add([]), throwsUnsupportedError);
    expect(() => result.rows.first.add(1), throwsUnsupportedError);
    expect(() => (result.rows.first[0] as List).add(1), throwsUnsupportedError);
    expect(
      () => (result.rows.first[1] as Map)['name'] = 'changed',
      throwsUnsupportedError,
    );
    await database.close();
    expect((result.rows.first[1] as Map)['name'], 'Alice');
  });

  test('preserve graph node, relationship, and path fields', () async {
    await contacts();
    await database.query('CREATE (:Person {id:2,name:\'Bob\'});');
    await database.query('CREATE REL TABLE KNOWS(FROM Person TO Person);');
    await database.query(
      'MATCH (a:Person {id:1}),(b:Person {id:2}) CREATE (a)-[:KNOWS]->(b);',
    );
    final result = await database.query(
      'MATCH p=(a:Person {id:1})-[r:KNOWS]->(b:Person) RETURN a,r,p;',
    );
    expect((result.rows.single[0] as Map)['name'], 'Alice');
    expect((result.rows.single[1] as Map)['_LABEL'], 'KNOWS');
    final graphPath = result.rows.single[2] as Map;
    expect(graphPath['length'], 1);
    expect((graphPath['nodes'] as List).length, 2);
    expect((graphPath['rels'] as List).length, 1);
  });

  test('preserve dates, timestamps, and non-finite results', () async {
    final result = await database.query(
      "RETURN date('1970-01-02'), timestamp('1970-01-01 00:00:01'), "
      "INTERVAL('1 day'), CAST('NaN','DOUBLE'), CAST('Infinity','DOUBLE');",
    );
    expect(result.rows.single[0], 86400000);
    expect(result.rows.single[1], 1000);
    expect(result.rows.single[2], isA<String>());
    expect((result.rows.single[3] as double).isNaN, isTrue);
    expect(result.rows.single[4], double.infinity);
  });

  test('empty results retain column names and types', () async {
    await contacts();
    final result = await database.query(
      'MATCH (p:Person) WHERE p.id=999 RETURN p.name AS name;',
    );
    expect(result.rows, isEmpty);
    expect(result.columns.single.name, 'name');
    expect(result.columns.single.type, NeugType.string);
  });

  test('support list parameters and empty lists', () async {
    await contacts();
    for (final ids in <List<int>>[
      [1, 2],
      [],
    ]) {
      final result = await database.query(
        'MATCH (p:Person) WHERE p.id IN \$ids RETURN p.name;',
        parameters: {'ids': ids},
      );
      expect(result.rows.length, ids.isEmpty ? 0 : 1);
    }
  });

  test('snapshot parameters when the query is called', () async {
    await contacts();
    final parameters = <String, Object?>{'name': 'first'};
    final update = database.query(
      'MATCH (p:Person {id:1}) SET p.name=\$name;',
      parameters: parameters,
    );
    parameters['name'] = 'second';
    await update;
    expect(await name(), 'first');
  });

  test('serialize concurrently submitted operations', () async {
    await contacts();
    await Future.wait([
      for (var id = 2; id <= 12; id++)
        database.query(
          'CREATE (:Person {id:\$id,name:\$name});',
          parameters: {'id': id, 'name': '$id'},
        ),
    ]);
    expect(
      (await database.query('MATCH (p:Person) RETURN count(p);')).rows.single,
      [12],
    );
  });

  test('commit transactions and roll back application exceptions', () async {
    await contacts();
    final value = await database.transaction((transaction) async {
      await transaction.query(
        'MATCH (p:Person {id:1}) SET p.name=\$name;',
        parameters: {'name': 'committed'},
      );
      return 42;
    });
    expect(value, 42);
    expect(await name(), 'committed');
    final failure = StateError('rollback');
    await expectLater(
      database.transaction<void>((transaction) async {
        await transaction.query("MATCH (p:Person {id:1}) SET p.name='bad';");
        throw failure;
      }),
      throwsA(same(failure)),
    );
    expect(await name(), 'committed');
  });

  test('external queries do not interleave with a transaction', () async {
    await contacts();
    final entered = Completer<void>();
    final proceed = Completer<void>();
    final transaction = database.transaction((transaction) async {
      await transaction.query("MATCH (p:Person {id:1}) SET p.name='first';");
      entered.complete();
      await proceed.future;
      await transaction.query("MATCH (p:Person {id:1}) SET p.name='second';");
    });
    await entered.future;
    final outside = name();
    proceed.complete();
    await transaction;
    expect(await outside, 'second');
  });

  test('reject expired or nested transactions and misuse', () async {
    late NeugTransaction captured;
    await database.transaction((transaction) {
      captured = transaction;
    });
    await expectLater(captured.query('RETURN 1;'), throwsStateError);
    await expectLater(
      database.transaction((_) => database.query('RETURN 1;')),
      throwsStateError,
    );
    await expectLater(
      database.transaction((_) => database.transaction((_) => 1)),
      throwsStateError,
    );
    await expectLater(
      database.transaction((_) => database.close()),
      throwsStateError,
    );
    expect((await database.query('RETURN 1;')).rows.single, [1]);
  });

  test('avoid deadlocks in cross-database callbacks', () async {
    final other = await NeugDatabase.open(':memory:');
    try {
      await expectLater(
        database.transaction(
          (_) => other.transaction((_) => database.query('RETURN 1;')),
        ),
        throwsStateError,
      );
      expect((await database.query('RETURN 1;')).rows.single, [1]);
      expect((await other.query('RETURN 2;')).rows.single, [2]);
    } finally {
      await other.close();
    }
  });

  test('roll back failed queries and keep the database usable', () async {
    await contacts();
    await expectLater(
      database.transaction((transaction) async {
        await transaction.query("MATCH (p:Person {id:1}) SET p.name='bad';");
        await transaction.query('THIS IS NOT CYPHER');
      }),
      throwsA(isA<NeugException>()),
    );
    expect(await name(), 'Alice');
  });

  test('reject missing or mistyped parameters and zero bytes', () async {
    await contacts();
    for (final parameters in <Map<String, Object?>>[
      {},
      {'id': 'wrong'},
    ]) {
      await expectLater(
        database.query(
          'MATCH (p:Person {id:\$id}) RETURN p.name;',
          parameters: parameters,
        ),
        throwsA(isA<NeugException>()),
      );
    }
    await expectLater(
      database.query('RETURN 1;\u0000junk'),
      throwsA(isA<NeugException>()),
    );
    expect(await name(), 'Alice');
  });

  test('read-only databases allow reads and reject writes', () async {
    await contacts();
    await database.close();
    database = await NeugDatabase.open(path, readOnly: true);
    expect(await name(), 'Alice');
    await expectLater(
      database.query("MATCH (p:Person {id:1}) SET p.name='bad';"),
      throwsA(isA<NeugException>()),
    );
  });

  test('read-only transactions reject writes and allow rollback', () async {
    await contacts();
    await expectLater(
      database.transaction(
        (transaction) =>
            transaction.query("MATCH (p:Person {id:1}) SET p.name='bad';"),
        readOnly: true,
      ),
      throwsA(isA<NeugException>()),
    );
    expect(await name(), 'Alice');
  });

  test('close waits, rejects new work, and is repeatable', () async {
    final entered = Completer<void>();
    final proceed = Completer<void>();
    final transaction = database.transaction((transaction) async {
      entered.complete();
      await proceed.future;
      await transaction.query('RETURN 1;');
    });
    await entered.future;
    final closing = database.close();
    await expectLater(database.query('RETURN 1;'), throwsStateError);
    proceed.complete();
    await transaction;
    await Future.wait([closing, database.close()]);
    expect(database.isClosed, isTrue);
    await expectLater(database.query('RETURN 1;'), throwsStateError);
  });

  test('recover and retry after close preparation fails', () async {
    await contacts();
    final runtime = Directory('$path/runtime');
    final saved = '${runtime.path}.saved';
    await runtime.rename(saved);
    try {
      await File(runtime.path).writeAsString('block');
      await expectLater(database.close(), throwsA(isA<NeugException>()));
      expect(database.isClosed, isFalse);
    } finally {
      await File(runtime.path).delete();
      await Directory(saved).rename(runtime.path);
    }
    await database.close();
    expect(database.isClosed, isTrue);
  });

  test('release handles after close publication failure', () async {
    await contacts();
    final current = File('$path/checkpoint/CURRENT');
    final saved = File('${current.path}.saved');
    final existed = await current.exists();
    if (existed) await current.rename(saved.path);
    final block = await Directory(current.path).create();
    try {
      await File('${block.path}/block').writeAsString('block');
      await expectLater(database.close(), throwsA(isA<NeugException>()));
      expect(database.isClosed, isTrue);
      await database.close();
    } finally {
      await block.delete(recursive: true);
      if (existed) await saved.rename(current.path);
    }
  });

  test('failed opens leave no active worker isolate', () async {
    final file = await File(
      '${directory.path}/file',
    ).writeAsString('not a database');
    await expectLater(
      NeugDatabase.open(file.path),
      throwsA(isA<NeugException>()),
    );
    expect((await database.query('RETURN 1;')).rows.single, [1]);
  });
}
