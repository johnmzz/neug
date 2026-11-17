import 'dart:convert';

import 'package:neug/src/parameters.dart';
import 'package:test/test.dart';

void main() {
  test('JSON escaping and full UINT64 integer text', () {
    final maximum = (BigInt.one << 64) - BigInt.one;
    final json = encodeParameters({
      'id': maximum,
      'name': "\u4e2d\u6587'\\\n\u0000",
    });
    expect(json, contains('18446744073709551615'));
    expect((jsonDecode(json) as Map)['name'], "\u4e2d\u6587'\\\n\u0000");
  });

  test('reject unrepresentable values and cyclic references', () {
    final cycle = <Object?>[];
    cycle.add(cycle);
    for (final value in <Object?>[
      double.nan,
      double.infinity,
      BigInt.one << 64,
      -(BigInt.one << 63) - BigInt.one,
      DateTime.utc(2026),
      {1: 'not a string key'},
      cycle,
    ]) {
      expect(() => encodeParameters({'value': value}), throwsArgumentError);
    }
  });

  test('reject excessive nesting but allow shared acyclic containers', () {
    Object value = 1;
    for (var i = 0; i < 65; i++) {
      value = [value];
    }
    expect(() => encodeParameters({'value': value}), throwsArgumentError);
    final shared = [1, null];
    expect(jsonDecode(encodeParameters({'a': shared, 'b': shared})), {
      'a': [1, null],
      'b': [1, null],
    });
  });
}
