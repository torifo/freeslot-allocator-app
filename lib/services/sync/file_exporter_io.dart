/// Phone → PC hand-off with no network at all: write the sync document to a
/// `.json` file and let the user move it (share sheet on mobile, a save dialog
/// on desktop). The app itself never sends the file anywhere.
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'file_exporter_common.dart';
import 'sync_document.dart';

export 'file_exporter_common.dart';

/// Writes [doc] as `frelocator-<deviceId>-<stamp>.json` and returns its path.
///
/// [directory] defaults to the app's temporary directory, which is where the
/// share sheet expects to find a file it is about to hand off.
Future<String> writeExportFile(SyncDocument doc, {String? directory}) async {
  final dir = directory ?? (await getTemporaryDirectory()).path;
  final file = File('$dir/${exportFileName(doc)}');
  await file.writeAsString(encodeExport(doc), flush: true);
  return file.path;
}

/// Hands the export to the platform: the share sheet on Android and iOS (the
/// user picks Nearby Share, AirDrop, a cable, …), a save dialog everywhere
/// else. Returns false only when the user backed out — dismissed the share
/// sheet, or cancelled the save dialog without choosing a destination.
///
/// On the PC side the file is read back by Claude Code's `import_file` tool or
/// by the macOS build's 「ファイルから取り込む」.
Future<bool> shareExportFile(SyncDocument doc) async {
  const guide =
      'FRELOCATOR のデータ書き出しです。PC 側では Claude の import_file か、'
      'macOS 版アプリの「ファイルから取り込む」で読み込みます。';
  if (Platform.isAndroid || Platform.isIOS) {
    final path = await writeExportFile(doc);
    final result = await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(path, mimeType: 'application/json')],
        subject: 'FRELOCATOR export',
        text: guide,
      ),
    );
    // Android and several iOS targets report `unavailable` even when the hand-off
    // worked, so only an explicit dismissal counts as the user backing out.
    return result.status != ShareResultStatus.dismissed;
  }
  // `file_picker` only creates the file when it is handed the bytes, so the
  // desktop path never leaves a stray copy in the temporary directory.
  final saved = await FilePicker.platform.saveFile(
    dialogTitle: 'FRELOCATOR のデータを書き出す',
    fileName: exportFileName(doc),
    type: FileType.custom,
    allowedExtensions: const <String>['json'],
    bytes: utf8.encode(encodeExport(doc)),
  );
  if (saved == null) return false;
  // macOS writes the bytes itself, Linux and Windows hand back the chosen path
  // without writing anything, and the path may already hold a stale export of
  // the same name. Writing unconditionally is the only behaviour correct on all
  // three.
  await File(saved).writeAsString(encodeExport(doc), flush: true);
  return true;
}

/// Reads and validates an export file, returning the raw JSON — exactly what
/// `SyncService.applyReceived` takes, so the macOS import merges through the
/// same path as a LAN or QR sync.
///
/// Throws [FormatException] when the file is too large, unreadable or not a
/// valid v2 document.
Future<Map<String, dynamic>> readImportJson(String path) async {
  final file = File(path);
  final int length;
  try {
    length = await file.length();
  } on FileSystemException {
    throw const FormatException('ファイルを読み込めません');
  }
  if (length > kMaxImportBytes) {
    throw FormatException(
      'ファイルが大きすぎます (${kMaxImportBytes ~/ (1024 * 1024)} MB まで)',
    );
  }
  final String text;
  try {
    text = await file.readAsString();
  } on FileSystemException {
    throw const FormatException('ファイルを読み込めません');
  }
  return parseImportJson(text);
}

/// [readImportJson] as a parsed document, for callers that only want to show
/// what the file contains.
Future<SyncDocument> readImportFile(String path) async =>
    SyncDocument.fromJson(await readImportJson(path), strict: true);

/// Opens the platform file chooser for a `.json` export. Returns null when the
/// user cancelled.
Future<String?> pickImportFile() async {
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'FRELOCATOR の書き出しファイルを選ぶ',
    type: FileType.custom,
    allowedExtensions: const <String>['json'],
  );
  return result?.files.single.path;
}
