import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'sync_meta.dart';

/// SHA-256 of the entity's content with sync meta removed and keys sorted, so
/// Dart and TypeScript compute the same value for the same entity.
///
/// Canonicalization notes so both sides agree byte-for-byte:
///  - Map keys are sorted by UTF-16 code unit, matching JavaScript's default
///    `Array.prototype.sort()` over `Object.keys()`.
///  - Non-ASCII characters are left unescaped, matching `JSON.stringify`.
///  - A `double` with no fractional part (and within the safe integer range)
///    is emitted as an integer, matching how JS numbers serialize.
String contentHash(Map<String, dynamic> entity) {
  final canonical = _canonicalize(
    Map<String, dynamic>.fromEntries(
      entity.entries.where((e) => !SyncMeta.keys.contains(e.key)),
    ),
  );
  return sha256.convert(utf8.encode(canonical)).toString();
}

const _maxSafeInteger = 9007199254740992;

String _canonicalize(dynamic value) {
  if (value is Map) {
    for (final key in value.keys) {
      if (key is! String) {
        throw ArgumentError.value(key, 'key', 'contentHash only supports String map keys');
      }
    }
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonicalize(value[k])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalize).join(',')}]';
  }
  if (value is double && value == value.truncateToDouble() && value.abs() < _maxSafeInteger) {
    return value.toInt().toString();
  }
  return jsonEncode(value);
}
