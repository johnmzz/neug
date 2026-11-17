import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings_generated.dart' as c;
import 'result.dart';

String _decode(c.neug_string_view value) =>
    utf8.decode(value.data.cast<Uint8>().asTypedList(value.size));

void _check(int status, Pointer<Pointer<c.neug_error>> error) {
  if (status == 0) return;
  try {
    final message = error.value == nullptr
        ? 'NeuG returned error $status'
        : _decode(c.neug_error_message(error.value));
    throw NeugException(status, message);
  } finally {
    c.neug_error_destroy(error);
  }
}

c.neug_string_view _text(String text, Arena arena) {
  final bytes = utf8.encode(text);
  final data = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  data.asTypedList(bytes.length).setAll(0, bytes);
  final view = arena<c.neug_string_view>();
  view.ref
    ..data = data.cast<Char>()
    ..size = bytes.length;
  return view.ref;
}

/// Use only in the database worker isolate; native pointers are not exposed to
/// callers.
final class NativeDatabase {
  NativeDatabase._();

  Pointer<c.neug_database> _database = nullptr;
  Pointer<c.neug_connection> _connection = nullptr;

  bool get isClosed => _database == nullptr;

  static NativeDatabase open(String path, bool readOnly) {
    final database = NativeDatabase._();
    try {
      using((arena) {
        final error = arena<Pointer<c.neug_error>>();
        final options = arena<c.neug_db_options>();
        c.neug_db_options_init(options);
        options.ref
          ..path = _text(path, arena)
          ..read_only = readOnly ? 1 : 0;
        final output = arena<Pointer<c.neug_database>>();
        _check(c.neug_db_open(options, output, error), error);
        database._database = output.value;
        final connection = arena<Pointer<c.neug_connection>>();
        _check(c.neug_db_connect(database._database, connection, error), error);
        database._connection = connection.value;
      });
      return database;
    } catch (error, stack) {
      try {
        database.close();
      } catch (cleanupError) {
        Error.throwWithStackTrace(
          NeugException(
            -1,
            'Open failed: $error; cleanup also failed: $cleanupError',
          ),
          stack,
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  NeugResult query(String query, String parameters) => using((arena) {
    final error = arena<Pointer<c.neug_error>>();
    final output = arena<Pointer<c.neug_result>>();
    _check(
      c.neug_query(
        _connection,
        _text(query, arena),
        _text(parameters, arena),
        output,
        error,
      ),
      error,
    );
    try {
      return _ResultReader(arena, error).read(output.value);
    } finally {
      c.neug_result_destroy(output);
    }
  });

  void begin(bool readOnly) => using((arena) {
    final error = arena<Pointer<c.neug_error>>();
    _check(
      c.neug_connection_begin(_connection, readOnly ? 1 : 0, error),
      error,
    );
  });

  void commit() => using((arena) {
    final error = arena<Pointer<c.neug_error>>();
    _check(c.neug_connection_commit(_connection, error), error);
  });

  void rollback() => using((arena) {
    final error = arena<Pointer<c.neug_error>>();
    _check(c.neug_connection_rollback(_connection, error), error);
  });

  void close() {
    if (isClosed) return;
    using((arena) {
      final error = arena<Pointer<c.neug_error>>();
      final connection = arena<Pointer<c.neug_connection>>()
        ..value = _connection;
      _check(c.neug_connection_destroy(connection, error), error);
      _connection = connection.value;
      Object? closeError;
      StackTrace? closeStack;
      try {
        _check(c.neug_db_close(_database, error), error);
      } catch (failure, stack) {
        closeError = failure;
        closeStack = stack;
      }
      final closed = arena<Uint8>();
      _check(c.neug_db_is_closed(_database, closed, error), error);
      if (closed.value != 0) {
        final output = arena<Pointer<c.neug_database>>()..value = _database;
        _check(c.neug_db_destroy(output, error), error);
        _database = output.value;
      }
      if (closeError != null) {
        Error.throwWithStackTrace(closeError, closeStack!);
      }
    });
  }
}

final class _ResultReader {
  _ResultReader(this.arena, this.error);

  final Arena arena;
  final Pointer<Pointer<c.neug_error>> error;
  late final _integer = arena<Int64>();
  late final _unsigned = arena<Uint64>();
  late final _number = arena<Double>();
  late final _boolean = arena<Uint8>();
  late final _type = arena<Int32>();
  late final _string = arena<c.neug_string_view>();
  final _views = <Pointer<c.neug_value_view>>[];

  Pointer<c.neug_value_view> _view(int depth) {
    if (_views.length <= depth) _views.add(arena<c.neug_value_view>());
    return _views[depth];
  }

  NeugType _readType(int type) => switch (type) {
    c.NEUG_TYPE_NULL => NeugType.nullValue,
    c.NEUG_TYPE_BOOL => NeugType.boolean,
    c.NEUG_TYPE_INT32 => NeugType.int32,
    c.NEUG_TYPE_UINT32 => NeugType.uint32,
    c.NEUG_TYPE_INT64 => NeugType.int64,
    c.NEUG_TYPE_UINT64 => NeugType.uint64,
    c.NEUG_TYPE_FLOAT => NeugType.float,
    c.NEUG_TYPE_DOUBLE => NeugType.doubleValue,
    c.NEUG_TYPE_STRING => NeugType.string,
    c.NEUG_TYPE_DATE => NeugType.date,
    c.NEUG_TYPE_TIMESTAMP => NeugType.timestamp,
    c.NEUG_TYPE_INTERVAL => NeugType.interval,
    c.NEUG_TYPE_LIST => NeugType.list,
    c.NEUG_TYPE_STRUCT => NeugType.struct,
    c.NEUG_TYPE_TUPLE => NeugType.tuple,
    c.NEUG_TYPE_NODE => NeugType.node,
    c.NEUG_TYPE_RELATIONSHIP => NeugType.relationship,
    c.NEUG_TYPE_PATH => NeugType.path,
    c.NEUG_TYPE_OBJECT => NeugType.object,
    c.NEUG_TYPE_UNKNOWN => NeugType.unknown,
    _ => throw NeugException(
      c.NEUG_ERROR_NOT_SUPPORTED,
      'Unsupported result type code: $type',
    ),
  };

  NeugResult read(Pointer<c.neug_result> result) {
    _check(c.neug_result_column_count(result, _unsigned, error), error);
    final count = _unsigned.value;
    final columns = <NeugColumn>[];
    for (var i = 0; i < count; i++) {
      _check(c.neug_result_column_name(result, i, _string, error), error);
      final name = _decode(_string.ref);
      _check(c.neug_result_column_type(result, i, _type, error), error);
      columns.add(NeugColumn(name, _readType(_type.value)));
    }
    _check(c.neug_result_row_count(result, _unsigned, error), error);
    final rows = _unsigned.value;
    final data = <List<Object?>>[];
    for (var row = 0; row < rows; row++) {
      final values = <Object?>[];
      for (var column = 0; column < count; column++) {
        final view = _view(0);
        _check(
          c.neug_result_get_value(result, row, column, view, error),
          error,
        );
        values.add(_readValue(view, 0));
      }
      data.add(values);
    }
    return NeugResult(columns, data);
  }

  Object? _readValue(Pointer<c.neug_value_view> view, int depth) {
    if (depth > 64) {
      throw const NeugException(
        c.NEUG_ERROR_OVERFLOW,
        'Result nesting depth exceeds 64',
      );
    }
    _check(c.neug_value_is_null(view, _boolean, error), error);
    if (_boolean.value != 0) return null;
    _check(c.neug_value_type(view, _type, error), error);
    switch (_readType(_type.value)) {
      case NeugType.nullValue:
        return null;
      case NeugType.boolean:
        _check(c.neug_value_get_bool(view, _boolean, error), error);
        return _boolean.value != 0;
      case NeugType.int32 ||
          NeugType.int64 ||
          NeugType.date ||
          NeugType.timestamp:
        _check(c.neug_value_get_int64(view, _integer, error), error);
        return _integer.value;
      case NeugType.uint32 || NeugType.uint64:
        _check(c.neug_value_get_uint64(view, _unsigned, error), error);
        final value = _unsigned.value;
        return value < 0 ? BigInt.from(value).toUnsigned(64) : value;
      case NeugType.float || NeugType.doubleValue:
        _check(c.neug_value_get_double(view, _number, error), error);
        return _number.value;
      case NeugType.string || NeugType.interval:
        _check(c.neug_value_get_string(view, _string, error), error);
        return _decode(_string.ref);
      case NeugType.list || NeugType.tuple:
        _check(c.neug_value_size(view, _unsigned, error), error);
        final size = _unsigned.value;
        final values = <Object?>[];
        for (var i = 0; i < size; i++) {
          final child = _view(depth + 1);
          _check(c.neug_value_child(view, i, child, error), error);
          values.add(_readValue(child, depth + 1));
        }
        return List<Object?>.unmodifiable(values);
      case NeugType.struct ||
          NeugType.node ||
          NeugType.relationship ||
          NeugType.path ||
          NeugType.object:
        _check(c.neug_value_size(view, _unsigned, error), error);
        final size = _unsigned.value;
        final fields = <String, Object?>{};
        for (var i = 0; i < size; i++) {
          _check(c.neug_value_field_name(view, i, _string, error), error);
          final name = _decode(_string.ref);
          final child = _view(depth + 1);
          _check(c.neug_value_child(view, i, child, error), error);
          fields[name] = _readValue(child, depth + 1);
        }
        return Map<String, Object?>.unmodifiable(fields);
      case NeugType.unknown:
        throw const NeugException(
          c.NEUG_ERROR_NOT_SUPPORTED,
          'Unsupported query result type',
        );
    }
  }
}
