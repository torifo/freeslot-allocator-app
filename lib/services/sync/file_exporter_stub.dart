/// Web fallback: there is no file system to write an export to and no share
/// sheet to hand it to, so every entry point refuses instead of pretending.
library;

import 'sync_document.dart';

export 'file_exporter_common.dart';

Never _unsupported() =>
    throw UnsupportedError('ファイルの書き出し・取り込みはこの環境では使えません');

Future<String> writeExportFile(SyncDocument doc, {String? directory}) async =>
    _unsupported();

Future<bool> shareExportFile(SyncDocument doc) async => _unsupported();

Future<Map<String, dynamic>> readImportJson(String path) async =>
    _unsupported();

Future<SyncDocument> readImportFile(String path) async => _unsupported();

Future<String?> pickImportFile() async => _unsupported();
