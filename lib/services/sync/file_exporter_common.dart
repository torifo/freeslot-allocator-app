/// Naming and validation shared by every platform's file export/import.
///
/// Nothing here touches `dart:io`, so the web build can import it too.
library;

import 'dart:convert';

import 'sync_document.dart';

/// The hub refuses anything larger (`MAX_BODY` in `tools/hub/src/tools.ts`), so
/// there is no point in writing or reading a bigger file.
const int kMaxImportBytes = 20 * 1024 * 1024;

/// Everything outside this set is replaced in the file name: a device id comes
/// from the device itself and must never be able to steer the path.
final RegExp _unsafe = RegExp(r'[^A-Za-z0-9_-]');

/// `20260909-010203`, always in UTC so two devices never disagree about the
/// order of their exports.
String exportStamp(DateTime at) {
  final u = at.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}${two(u.month)}${two(u.day)}'
      '-${two(u.hour)}${two(u.minute)}${two(u.second)}';
}

/// `frelocator-<deviceId>-<stamp>.json` — a plain `.json` name the hub's
/// `import_file` accepts as-is.
String exportFileName(SyncDocument doc) {
  final device = doc.deviceId.replaceAll(_unsafe, '-');
  final id = device.isEmpty ? 'device' : device;
  return 'frelocator-$id-${exportStamp(doc.exportedAt)}.json';
}

/// The bytes written to the file: the whole v2 document, pretty-printed so a
/// human can eyeball it, with UTC `Z` timestamps and the mandatory `settings`
/// block that [SyncDocument.toJson] always emits.
String encodeExport(SyncDocument doc) {
  final json = doc.toJson();
  assert(json['version'] == SyncDocument.schemaVersion);
  assert((json['taskMaster'] as Map)['settings'] != null);
  return '${const JsonEncoder.withIndent('  ').convert(json)}\n';
}

/// Parses the text of an export file the way the hub does, and no more
/// leniently: only a v2-or-newer object, and only one this build understands.
///
/// Throws [FormatException] for anything malformed and
/// [UnsupportedSchemaException] for a schema written by a newer build.
Map<String, dynamic> parseImportJson(String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException catch (error) {
    // The parser message quotes the offending bytes; keep file content out of it.
    throw FormatException('JSON として読めません (${error.offset ?? 0} 文字目)');
  }
  if (json is! Map<String, dynamic>) {
    throw const FormatException('JSON のトップレベルがオブジェクトではありません');
  }
  final version = json['version'];
  if (version is! num || version < SyncDocument.schemaVersion) {
    throw FormatException('スキーマ v2 のファイルだけ取り込めます (version: $version)');
  }
  // Surfaces UnsupportedSchemaException for a newer schema, and FormatException
  // for a v2 file with missing or mistyped fields.
  SyncDocument.fromJson(json, strict: true);
  return json;
}
