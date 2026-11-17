import 'dart:convert';

final _minimumInt64 = -(BigInt.one << 63);
final _maximumUint64 = (BigInt.one << 64) - BigInt.one;

/// Preserve BigInt precision using JSON integer text without conversion through
/// double.
String encodeParameters(Map<String, Object?> parameters) {
  final output = StringBuffer();
  final parents = Set<Object>.identity();

  void write(Object? value, int depth) {
    if (depth > 64) {
      throw ArgumentError('Parameter JSON nesting depth must not exceed 64');
    }
    switch (value) {
      case null || bool() || String() || int():
        output.write(jsonEncode(value));
      case double():
        if (!value.isFinite) {
          throw ArgumentError.value(
            value,
            'parameters',
            'JSON does not support NaN or infinity',
          );
        }
        output.write(jsonEncode(value));
      case BigInt():
        if (value < _minimumInt64 || value > _maximumUint64) {
          throw ArgumentError.value(
            value,
            'parameters',
            'Integer is outside the NeuG 64-bit range',
          );
        }
        output.write(value);
      case List():
        if (!parents.add(value)) {
          throw ArgumentError('Parameters contain a cyclic reference');
        }
        output.write('[');
        for (var i = 0; i < value.length; i++) {
          if (i != 0) output.write(',');
          write(value[i], depth + 1);
        }
        output.write(']');
        parents.remove(value);
      case Map():
        if (!parents.add(value)) {
          throw ArgumentError('Parameters contain a cyclic reference');
        }
        output.write('{');
        var first = true;
        for (final entry in value.entries) {
          if (entry.key is! String) {
            throw ArgumentError('Parameter map keys must be strings');
          }
          if (!first) output.write(',');
          first = false;
          output.write(jsonEncode(entry.key));
          output.write(':');
          write(entry.value, depth + 1);
        }
        output.write('}');
        parents.remove(value);
      default:
        throw ArgumentError.value(
          value,
          'parameters',
          'Only JSON values and 64-bit BigInt values are supported; pass dates as milliseconds or strings',
        );
    }
  }

  write(parameters, 0);
  return output.toString();
}
