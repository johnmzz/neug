import 'dart:async';
import 'dart:isolate';

import 'native_database.dart';
import 'parameters.dart';
import 'result.dart';

final _transactionZone = Object();
Set<NeugDatabase> get _transactionDatabases =>
    Zone.current[_transactionZone] as Set<NeugDatabase>? ??
    const <NeugDatabase>{};

/// One background isolate, one database, and one connection.
///
/// Operations on an instance execute in call order. Always await close() when
/// finished.
final class NeugDatabase {
  NeugDatabase._(this._worker);

  final _Worker _worker;
  Future<void> _tail = Future.value();
  Future<void>? _closing;
  bool _closed = false;

  static Future<NeugDatabase> open(
    String path, {
    bool readOnly = false,
  }) async => NeugDatabase._(await _Worker.start(path, readOnly));

  bool get isClosed => _closed || _worker.exited;

  void _checkAccess() {
    if (_transactionDatabases.contains(this)) {
      throw StateError(
        'Use the supplied NeugTransaction inside a transaction callback',
      );
    }
    if (isClosed || _closing != null) {
      throw StateError('The database is closed or closing');
    }
  }

  Future<T> _schedule<T>(Future<T> Function() action) {
    _checkAccess();
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Execute queries, schema changes, and writes; await and discard the result
  /// when it is not needed.
  Future<NeugResult> query(
    String query, {
    Map<String, Object?> parameters = const {},
  }) => Future.sync(() {
    _checkAccess();
    final json = encodeParameters(parameters);
    return _schedule(() => _worker.query(query, json));
  });

  /// Regular queries and other transactions queue behind the active
  /// transaction.
  /// Roll back if the callback throws; commit on success. Nested transactions
  /// on the same database are not supported.
  Future<T> transaction<T>(
    FutureOr<T> Function(NeugTransaction transaction) action, {
    bool readOnly = false,
  }) => Future.sync(
    () => _schedule(() async {
      await _worker.request(_Operation.begin, readOnly: readOnly);
      final transaction = NeugTransaction._(this);
      try {
        final result = await runZoned(
          () => action(transaction),
          zoneValues: {
            _transactionZone: {..._transactionDatabases, this},
          },
        );
        await transaction._finish();
        await _worker.request(_Operation.commit);
        return result;
      } catch (error, stack) {
        await transaction._finish();
        try {
          await _worker.request(_Operation.rollback);
        } catch (rollbackError) {
          Error.throwWithStackTrace(
            NeugTransactionException(error, rollbackError),
            stack,
          );
        }
        Error.throwWithStackTrace(error, stack);
      }
    }),
  );

  /// Wait for earlier operations before closing. Retry if closing fails and the
  /// native database remains open.
  Future<void> close() async {
    if (_transactionDatabases.contains(this)) {
      throw StateError(
        'Cannot close the database inside a transaction callback',
      );
    }
    if (isClosed) return;
    if (_closing != null) return _closing!;
    final closing = _schedule(() async {
      try {
        await _worker.request(_Operation.close);
      } finally {
        if (_worker.nativeClosed) {
          _closed = true;
          await _worker.dispose();
        } else {
          _closing = null;
        }
      }
    });
    _closing = closing;
    return closing;
  }
}

/// Valid only during the transaction callback; this object does not own a
/// separate connection.
final class NeugTransaction {
  NeugTransaction._(this._database);

  final NeugDatabase _database;
  Future<void> _tail = Future.value();
  bool _active = true;

  Future<NeugResult> query(
    String query, {
    Map<String, Object?> parameters = const {},
  }) => Future.sync(() {
    if (!_active || !_transactionDatabases.contains(_database)) {
      throw StateError(
        'A transaction object can only be used inside its callback',
      );
    }
    final json = encodeParameters(parameters);
    final result = _tail.then((_) => _database._worker.query(query, json));
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  });

  Future<void> _finish() {
    _active = false;
    return _tail;
  }
}

enum _Operation { query, begin, commit, rollback, close }

final class _Request {
  const _Request(
    this.id,
    this.operation,
    this.query,
    this.parameters,
    this.readOnly,
  );
  final int id;
  final _Operation operation;
  final String query;
  final String parameters;
  final bool readOnly;
}

final class _Reply {
  const _Reply(
    this.id, {
    this.value,
    this.error,
    this.stack,
    this.closed = false,
  });
  final int id;
  final Object? value;
  final NeugException? error;
  final String? stack;
  final bool closed;
}

final class _Start {
  const _Start(this.replies, this.path, this.readOnly);
  final SendPort replies;
  final String path;
  final bool readOnly;
}

final class _Worker {
  final _replies = ReceivePort();
  final _ready = Completer<SendPort>();
  final _exit = Completer<void>();
  final _pending = <int, Completer<Object?>>{};
  late final StreamSubscription<Object?> _subscription;
  late final SendPort _commands;
  bool nativeClosed = false;
  bool exited = false;
  int _sequence = 0;

  static Future<_Worker> start(String path, bool readOnly) async {
    final worker = _Worker();
    worker._subscription = worker._replies.listen(worker._receive);
    try {
      await Isolate.spawn(
        _workerMain,
        _Start(worker._replies.sendPort, path, readOnly),
        onError: worker._replies.sendPort,
        onExit: worker._replies.sendPort,
      );
    } catch (_) {
      await worker._subscription.cancel();
      worker._replies.close();
      rethrow;
    }
    try {
      worker._commands = await worker._ready.future;
      return worker;
    } catch (_) {
      await worker.dispose();
      rethrow;
    }
  }

  void _receive(Object? message) {
    if (message is SendPort) {
      _ready.complete(message);
    } else if (message is _Reply) {
      nativeClosed = message.closed;
      if (message.id == 0) {
        _ready.completeError(
          message.error!,
          StackTrace.fromString(message.stack ?? ''),
        );
        return;
      }
      final target = _pending.remove(message.id);
      if (message.error != null) {
        target?.completeError(
          message.error!,
          StackTrace.fromString(message.stack ?? ''),
        );
      } else {
        target?.complete(message.value);
      }
    } else {
      final error = NeugException(
        -1,
        message == null ? 'The database worker isolate has exited' : '$message',
      );
      if (!_ready.isCompleted) _ready.completeError(error);
      for (final pending in _pending.values) {
        pending.completeError(error);
      }
      _pending.clear();
      if (message == null) {
        exited = true;
        _exit.complete();
        unawaited(_subscription.cancel());
        _replies.close();
      }
    }
  }

  Future<Object?> request(
    _Operation operation, {
    String query = '',
    String parameters = '{}',
    bool readOnly = false,
  }) {
    if (exited) {
      return Future.error(StateError('The database worker isolate has exited'));
    }
    final id = ++_sequence;
    final pending = Completer<Object?>();
    _pending[id] = pending;
    _commands.send(_Request(id, operation, query, parameters, readOnly));
    return pending.future;
  }

  Future<NeugResult> query(String query, String parameters) async =>
      (await request(_Operation.query, query: query, parameters: parameters))
          as NeugResult;

  Future<void> dispose() async {
    await _exit.future;
    await _subscription.cancel();
    _replies.close();
  }
}

NeugException _asException(Object error) =>
    error is NeugException ? error : NeugException(-1, '$error');

void _workerMain(_Start start) {
  final NativeDatabase database;
  try {
    database = NativeDatabase.open(start.path, start.readOnly);
  } catch (error, stack) {
    start.replies.send(
      _Reply(0, error: _asException(error), stack: '$stack', closed: true),
    );
    return;
  }
  final commands = ReceivePort();
  start.replies.send(commands.sendPort);
  commands.listen((Object? value) {
    final request = value! as _Request;
    try {
      Object? result;
      switch (request.operation) {
        case _Operation.query:
          result = database.query(request.query, request.parameters);
        case _Operation.begin:
          database.begin(request.readOnly);
        case _Operation.commit:
          database.commit();
        case _Operation.rollback:
          database.rollback();
        case _Operation.close:
          database.close();
      }
      start.replies.send(
        _Reply(request.id, value: result, closed: database.isClosed),
      );
    } catch (error, stack) {
      start.replies.send(
        _Reply(
          request.id,
          error: _asException(error),
          stack: '$stack',
          closed: database.isClosed,
        ),
      );
    }
    if (database.isClosed) commands.close();
  });
}
