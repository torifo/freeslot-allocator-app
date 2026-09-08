import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/sync/file_exporter.dart';
import 'package:frelocator/services/sync/sync_document.dart';

SyncDocument _doc({String deviceId = 'android-1'}) => SyncDocument(
  exportedAt: DateTime.utc(2026, 9, 9, 1, 2, 3),
  deviceId: deviceId,
  taskMaster: TaskMasterStateData.initial(),
  dailyPlan: DailyPlanStateData.initial(),
);

Map<String, dynamic> _validJson() => <String, dynamic>{
  'version': 2,
  'exportedAt': '2026-09-09T00:00:00.000Z',
  'deviceId': 'android-1',
  'taskMaster': TaskMasterStateData.initial().toJson(),
  'dailyPlan': DailyPlanStateData.initial().toJson(),
};

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  return dir;
}

/// Stands in for the desktop save dialog: it answers with a path and, like
/// `file_picker` on Linux and Windows, writes nothing itself.
class _FakeSaveFilePicker extends FilePicker {
  _FakeSaveFilePicker(this.answer);

  final String? answer;
  Uint8List? bytes;
  String? fileName;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    this.fileName = fileName;
    this.bytes = bytes;
    return answer;
  }
}

void main() {
  test('writes a v2 json file with a timestamped name into the given directory', () async {
    final dir = await _tempDir('frelocator-export-');
    final path = await writeExportFile(_doc(), directory: dir.path);

    expect(path, endsWith('frelocator-android-1-20260909-010203.json'));
    final json =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    expect(json['version'], 2);
    expect(json['deviceId'], 'android-1');
    // The hub merges on `settings`, so it must never be omitted.
    expect((json['taskMaster'] as Map<String, dynamic>)['settings'], isNotNull);
    expect(json['exportedAt'], '2026-09-09T01:02:03.000Z');
  });

  test('stamps the name in UTC even when the document carries a local time', () {
    final local = SyncDocument(
      exportedAt: DateTime.utc(2026, 9, 9, 1, 2, 3).toLocal(),
      deviceId: 'd',
      taskMaster: TaskMasterStateData.initial(),
      dailyPlan: DailyPlanStateData.initial(),
    );
    expect(exportFileName(local), 'frelocator-d-20260909-010203.json');
  });

  test('a device id can never steer the path', () {
    expect(
      exportFileName(_doc(deviceId: '../../etc/passwd')),
      'frelocator-------etc-passwd-20260909-010203.json',
    );
    expect(exportFileName(_doc(deviceId: '')), 'frelocator-device-20260909-010203.json');
  });

  test('the written file round-trips through readImportFile', () async {
    final dir = await _tempDir('frelocator-roundtrip-');
    final path = await writeExportFile(_doc(), directory: dir.path);
    final read = await readImportFile(path);
    expect(read.deviceId, 'android-1');
    expect(read.exportedAt, DateTime.utc(2026, 9, 9, 1, 2, 3));
  });

  test('readImportFile validates strictly', () async {
    final dir = await _tempDir('frelocator-import-');

    final bad = File('${dir.path}/bad.json')..writeAsStringSync('{"version": 1}');
    await expectLater(readImportFile(bad.path), throwsFormatException);

    final notJson = File('${dir.path}/not-json.json')..writeAsStringSync('nope');
    await expectLater(readImportFile(notJson.path), throwsFormatException);

    final notObject = File('${dir.path}/list.json')..writeAsStringSync('[]');
    await expectLater(readImportFile(notObject.path), throwsFormatException);

    final missingField = File('${dir.path}/missing.json')
      ..writeAsStringSync(jsonEncode(_validJson()..remove('deviceId')));
    await expectLater(readImportFile(missingField.path), throwsFormatException);

    await expectLater(
      readImportFile('${dir.path}/absent.json'),
      throwsFormatException,
    );

    final newer = File('${dir.path}/newer.json')
      ..writeAsStringSync(jsonEncode(_validJson()..['version'] = 99));
    await expectLater(
      readImportFile(newer.path),
      throwsA(isA<UnsupportedSchemaException>()),
    );

    final good = File('${dir.path}/good.json')
      ..writeAsStringSync(jsonEncode(_validJson()));
    expect((await readImportFile(good.path)).deviceId, 'android-1');
  });

  test('readImportJson hands back exactly what applyReceived takes', () async {
    final dir = await _tempDir('frelocator-apply-');
    final path = await writeExportFile(_doc(), directory: dir.path);
    final json = await readImportJson(path);
    // `SyncService.applyReceived` re-parses this map with `strict: true`.
    expect(SyncDocument.fromJson(json, strict: true).deviceId, 'android-1');
  });

  test('the desktop save writes the file at the chosen path', () async {
    // `file_picker` writes the bytes itself on macOS but hands back an
    // unwritten path on Linux and Windows, so the export must always write.
    final dir = await _tempDir('frelocator-save-');
    final target = '${dir.path}/chosen.json';
    final picker = _FakeSaveFilePicker(target);
    FilePicker.platform = picker;

    expect(await shareExportFile(_doc()), isTrue);
    expect(picker.fileName, 'frelocator-android-1-20260909-010203.json');
    expect(picker.bytes, isNotNull);
    expect(File(target).readAsStringSync(), encodeExport(_doc()));
  }, skip: Platform.isAndroid || Platform.isIOS);

  test('the desktop save overwrites a stale file of the same name', () async {
    final dir = await _tempDir('frelocator-save-stale-');
    final target = File('${dir.path}/chosen.json')
      ..writeAsStringSync('{"version": 2, "stale": true}');
    FilePicker.platform = _FakeSaveFilePicker(target.path);

    expect(await shareExportFile(_doc()), isTrue);
    expect(target.readAsStringSync(), encodeExport(_doc()));
  }, skip: Platform.isAndroid || Platform.isIOS);

  test('the desktop save reports the user backing out of the dialog', () async {
    FilePicker.platform = _FakeSaveFilePicker(null);
    expect(await shareExportFile(_doc()), isFalse);
  }, skip: Platform.isAndroid || Platform.isIOS);

  test('refuses a file larger than the hub would accept', () async {
    final dir = await _tempDir('frelocator-big-');
    final big = File('${dir.path}/big.json');
    final sink = big.openWrite();
    sink.write('{"version": 2, "pad": "');
    for (var i = 0; i < (kMaxImportBytes ~/ 1024) + 2; i += 1) {
      sink.write('x' * 1024);
    }
    sink.write('"}');
    await sink.close();
    expect(await big.length(), greaterThan(kMaxImportBytes));
    await expectLater(readImportJson(big.path), throwsFormatException);
  });
}
