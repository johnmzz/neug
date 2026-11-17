/// The type of a query result column.
enum NeugType {
  nullValue,
  boolean,
  int32,
  uint32,
  int64,
  uint64,
  float,
  doubleValue,
  string,
  date,
  timestamp,
  interval,
  list,
  struct,
  tuple,
  node,
  relationship,
  path,
  object,
  unknown,
}

final class NeugColumn {
  const NeugColumn(this.name, this.type);

  final String name;
  final NeugType type;
}

/// Results copied into Dart memory, valid even after the database is closed.
///
/// DATE and TIMESTAMP remain Unix epoch milliseconds in UTC; INTERVAL is a
/// string.
/// UINT64 values outside the signed 64-bit range become BigInt. Nested results
/// use lists and maps.
final class NeugResult {
  NeugResult(List<NeugColumn> columns, List<List<Object?>> rows)
    : columns = List.unmodifiable(columns),
      rows = List.unmodifiable(rows.map(List<Object?>.unmodifiable));

  final List<NeugColumn> columns;
  final List<List<Object?>> rows;
}

final class NeugException implements Exception {
  const NeugException(this.code, this.message);

  /// Preserve the C API status code; -1 indicates a worker isolate or library
  /// loading failure.
  final int code;
  final String message;

  @override
  String toString() => 'NeugException($code): $message';
}

/// Preserve both errors when the application operation and its rollback fail.
final class NeugTransactionException implements Exception {
  const NeugTransactionException(this.cause, this.rollbackError);

  final Object cause;
  final Object rollbackError;

  @override
  String toString() =>
      'Transaction failed: $cause; rollback also failed: $rollbackError';
}
