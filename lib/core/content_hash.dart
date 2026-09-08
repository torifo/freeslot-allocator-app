import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'sync_meta.dart';

/// SHA-256 of the entity's content with sync meta removed and keys sorted, so
/// Dart and TypeScript compute the same value for the same entity.
String contentHash(Map<String, dynamic> entity) {
  final canonical = _canonicalize(
    Map<String, dynamic>.fromEntries(
      entity.entries.where((e) => !SyncMeta.keys.contains(e.key)),
    ),
  );
  return sha256.convert(utf8.encode(canonical)).toString();
}

String _canonicalize(dynamic value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonicalize(value[k])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalize).join(',')}]';
  }
  return jsonEncode(value);
}
