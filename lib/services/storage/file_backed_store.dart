import 'dart:convert';
import 'dart:io';

import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import '../sync/sync_document.dart';
import 'state_store.dart';

/// JSON file store shared with frelocator-hub. Reads and writes the whole
/// [SyncDocument] under an advisory lock and replaces the file atomically.
class FileBackedStore extends StateStore {
  FileBackedStore({required this.directory, required this.deviceId});

  static String defaultDirectory() =>
      '${Platform.environment['HOME']}/Library/Application Support/FRELOCATOR';

  final String directory;
  final String deviceId;
  String? _lastWarning;
  DateTime? _lastReadModified;
  int? _lastReadLength;

  @override
  String? get lastWarning => _lastWarning;

  File get _file => File('$directory/data.json');
  File get _lock => File('$directory/data.lock');

  Future<T> _withLock<T>(Future<T> Function() body) async {
    await Directory(directory).create(recursive: true);
    final raf = await _lock.open(mode: FileMode.write);
    await raf.lock(FileLock.blockingExclusive);
    try {
      return await body();
    } finally {
      await raf.unlock();
      await raf.close();
    }
  }

  Future<SyncDocument> _readLocked() async {
    if (!await _file.exists()) {
      return _emptyDocument();
    }
    final text = await _file.readAsString();
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('root is not an object');
      }
      final doc = SyncDocument.fromJson(json);
      final stat = await _file.stat();
      _lastReadModified = stat.modified;
      _lastReadLength = stat.size;
      return doc;
    } on FormatException catch (error) {
      final quarantine =
          '$directory/data.json.broken-${DateTime.now().toUtc().millisecondsSinceEpoch}';
      await _file.rename(quarantine);
      _lastWarning =
          'data.json was corrupt ($error); moved to $quarantine and started '
          'with empty data (broken file kept).';
      return _emptyDocument();
    }
  }

  SyncDocument _emptyDocument() => SyncDocument(
    exportedAt: DateTime.now().toUtc(),
    deviceId: deviceId,
    taskMaster: TaskMasterStateData.initial(),
    dailyPlan: DailyPlanStateData.initial(),
  );

  Future<void> _writeLocked(SyncDocument doc) async {
    final tmp = File('$directory/data.json.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(doc.toJson()),
      flush: true,
    );
    if (await _file.exists()) {
      await _file.copy('$directory/data.json.bak');
    }
    await tmp.rename(_file.path);
    final stat = await _file.stat();
    _lastReadModified = stat.modified;
    _lastReadLength = stat.size;
  }

  @override
  Future<TaskMasterStateData> readTaskMaster() =>
      _withLock(() async => (await _readLocked()).taskMaster);

  @override
  Future<DailyPlanStateData> readDailyPlan() =>
      _withLock(() async => (await _readLocked()).dailyPlan);

  @override
  Future<void> writeTaskMaster(TaskMasterStateData state) => _withLock(() async {
    final current = await _readLocked();
    await _writeLocked(
      SyncDocument(
        exportedAt: DateTime.now().toUtc(),
        deviceId: deviceId,
        lastSyncAt: current.lastSyncAt,
        purgedBefore: current.purgedBefore,
        taskMaster: state,
        dailyPlan: current.dailyPlan,
      ),
    );
  });

  @override
  Future<void> writeDailyPlan(DailyPlanStateData state) => _withLock(() async {
    final current = await _readLocked();
    await _writeLocked(
      SyncDocument(
        exportedAt: DateTime.now().toUtc(),
        deviceId: deviceId,
        lastSyncAt: current.lastSyncAt,
        purgedBefore: current.purgedBefore,
        taskMaster: current.taskMaster,
        dailyPlan: state,
      ),
    );
  });

  @override
  Future<bool> changedSinceLastRead() async {
    if (!await _file.exists()) return _lastReadLength != null;
    final stat = await _file.stat();
    return stat.modified != _lastReadModified || stat.size != _lastReadLength;
  }
}
