import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:meta/meta.dart';

import '../../features/daily_plan/domain/daily_plan_models.dart';
import '../../features/task_master/domain/task_models.dart';
import '../sync/sync_document.dart';
import 'state_store.dart';

/// JSON file store shared with frelocator-hub. Reads and writes the whole
/// [SyncDocument] under a cross-process lock and replaces the file
/// atomically.
///
/// The hub (Node) locks with `proper-lockfile`, which does not use fcntl
/// advisory locks: it atomically `mkdir`s a sentinel directory
/// (`<dir>/data.lock.lock`), refreshes the sentinel's mtime periodically
/// while held, and removes it on release, treating it as stale after 10s
/// without a refresh. This class implements the same mechanism natively so
/// both processes exclude each other.
class FileBackedStore extends StateStore {
  FileBackedStore({
    required this.directory,
    required this.deviceId,
    this.lockTimeout = const Duration(seconds: 10),
    this.heartbeatInterval = const Duration(seconds: 2),
  });

  static const Duration _staleThreshold = Duration(seconds: 10);
  static const int _retryBaseDelayMs = 50;
  static const int _retryJitterMs = 20;

  static String defaultDirectory() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return Directory.systemTemp.path;
    }
    return '$home/Library/Application Support/FRELOCATOR';
  }

  final String directory;
  final String deviceId;

  /// How long [_withLock] will keep retrying to acquire the sentinel before
  /// giving up. Overridable in tests so they don't take 10 real seconds.
  final Duration lockTimeout;

  /// How often, while the lock is held, a transient file is created and
  /// immediately deleted inside the sentinel directory to refresh its
  /// mtime. Overridable in tests so they don't take 2 real seconds.
  final Duration heartbeatInterval;

  String? _lastWarning;
  DateTime? _lastReadModified;
  int? _lastReadLength;
  String? _lastReadEtag;

  @override
  String? get lastWarning => _lastWarning;

  File get _file => File('$directory/data.json');

  /// Plain marker file `proper-lockfile` requires to exist at the locked
  /// path; it is never itself locked (the sentinel directory is).
  File get _lockTargetFile => File('$directory/data.lock');

  Directory get _sentinel => Directory('$directory/data.lock.lock');

  Future<T> _withLock<T>(Future<T> Function() body) async {
    await Directory(directory).create(recursive: true);
    if (!await _lockTargetFile.exists()) {
      try {
        await _lockTargetFile.create();
      } catch (_) {
        // Best-effort: proper-lockfile only needs the target path to exist.
      }
    }
    await _acquireSentinel();
    final heartbeat = Timer.periodic(heartbeatInterval, (_) {
      unawaited(_refreshHeartbeat());
    });
    try {
      return await body();
    } finally {
      heartbeat.cancel();
      await _releaseSentinel();
    }
  }

  /// Test-only hook so tests can hold the lock open and assert that a
  /// second [FileBackedStore] instance on the same directory blocks until
  /// release.
  @visibleForTesting
  Future<T> withLockForTest<T>(Future<T> Function() body) => _withLock(body);

  Future<void> _acquireSentinel() async {
    final deadline = DateTime.now().add(lockTimeout);
    final random = Random();
    while (true) {
      if (await _tryCreateSentinelExclusive()) {
        await _refreshHeartbeat();
        return;
      }
      if (await _isSentinelStale()) {
        await _deleteSentinel();
        continue;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('data.lock is held by another process');
      }
      final jitter = random.nextInt(_retryJitterMs * 2 + 1) - _retryJitterMs;
      final delayMs = max(1, _retryBaseDelayMs + jitter);
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }
  }

  /// Atomically creates the sentinel directory, failing if it already
  /// exists — matching the `mkdir(2)` semantics `proper-lockfile` relies on
  /// (dart:io's `Directory.create()` is idempotent and does *not* throw
  /// when the directory already exists, so it cannot be used here).
  Future<bool> _tryCreateSentinelExclusive() async {
    try {
      final result = await Process.run('/bin/mkdir', [_sentinel.path]);
      return result.exitCode == 0;
    } on ProcessException {
      // Treat a failure to even spawn mkdir as a lock-acquisition failure so
      // the caller falls back to the normal retry/backoff loop.
      return false;
    }
  }

  Future<bool> _isSentinelStale() async {
    final mtime = await _sentinelMtime();
    if (mtime == null) {
      // The sentinel vanished (released concurrently) or its mtime is
      // unreadable; let the retry loop attempt to create it again.
      return false;
    }
    return DateTime.now().difference(mtime) > _staleThreshold;
  }

  /// `proper-lockfile` (the Node side) judges staleness solely from the
  /// sentinel directory's own mtime, so this must not rely on any file
  /// inside it.
  Future<DateTime?> _sentinelMtime() async {
    try {
      final dirStat = await _sentinel.stat();
      if (dirStat.type == FileSystemEntityType.notFound) return null;
      return dirStat.modified;
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteSentinel() async {
    try {
      await _sentinel.delete(recursive: true);
    } catch (_) {
      // Lost the race to reclaim it (another process deleted or
      // re-acquired first); the outer loop will retry create.
    }
  }

  /// Refreshes the sentinel directory's mtime the same way `proper-lockfile`
  /// does on Node (`utimes`): dart:io's `Directory` has no
  /// `setLastModified`, so instead a transient file is created inside the
  /// sentinel and immediately deleted, which bumps the directory's mtime on
  /// macOS. The sentinel must stay empty at all other times, since
  /// `proper-lockfile`'s stale-reclaim path does a non-recursive `rmdir`.
  Future<void> _refreshHeartbeat() async {
    final pulse = File(
      '${_sentinel.path}/.heartbeat-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await pulse.writeAsString('', flush: true);
    } catch (_) {
      // Best-effort: if the sentinel was removed concurrently, the next
      // acquire attempt re-establishes it.
      return;
    }
    try {
      await pulse.delete();
    } catch (_) {
      // Best-effort cleanup; if this fails the sentinel may briefly be
      // non-empty, which release() below already tolerates.
    }
  }

  /// Deletes the sentinel non-recursively, matching `proper-lockfile`'s
  /// `rmdir`. Falls back to a recursive delete (with a warning) only if the
  /// directory unexpectedly contains something, e.g. a heartbeat pulse that
  /// lost its cleanup race.
  Future<void> _releaseSentinel() async {
    try {
      await _sentinel.delete();
    } catch (_) {
      try {
        await _sentinel.delete(recursive: true);
        debugPrint(
          'FileBackedStore: sentinel ${_sentinel.path} was unexpectedly '
          'non-empty on release; deleted recursively.',
        );
      } catch (_) {
        // Ignore: already gone, or nothing we can do.
      }
    }
  }

  Future<SyncDocument> _readLocked() async {
    if (!await _file.exists()) {
      return _emptyDocument();
    }
    final text = await _file.readAsString();
    if (text.trim().isEmpty) {
      // Another process may be mid-write (tmp not yet renamed into place);
      // treat as "no data yet" without quarantining anything.
      return _emptyDocument();
    }
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('root is not an object');
      }
      final doc = SyncDocument.fromJson(json);
      final stat = await _file.stat();
      _lastReadModified = stat.modified;
      _lastReadLength = stat.size;
      _lastReadEtag = sha256.convert(utf8.encode(text)).toString();
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
    try {
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(doc.toJson()),
        flush: true,
      );
      if (await _file.exists()) {
        final bakTmp = File('$directory/data.json.bak.tmp');
        await _file.copy(bakTmp.path);
        await bakTmp.rename('$directory/data.json.bak');
      }
      await tmp.rename(_file.path);
    } catch (_) {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {
          // best-effort cleanup
        }
      }
      rethrow;
    }
    final stat = await _file.stat();
    _lastReadModified = stat.modified;
    _lastReadLength = stat.size;
    final text = await _file.readAsString();
    _lastReadEtag = sha256.convert(utf8.encode(text)).toString();
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

  /// One lock, one document, one rename: tasks and plans land together or not
  /// at all.
  @override
  Future<void> writeAll(TaskMasterStateData tasks, DailyPlanStateData plans) =>
      _withLock(() async {
        final current = await _readLocked();
        await _writeLocked(
          SyncDocument(
            exportedAt: DateTime.now().toUtc(),
            deviceId: deviceId,
            lastSyncAt: current.lastSyncAt,
            purgedBefore: current.purgedBefore,
            taskMaster: tasks,
            dailyPlan: plans,
          ),
        );
      });

  @override
  Future<bool> changedSinceLastRead() async {
    if (!await _file.exists()) return _lastReadLength != null;
    final stat = await _file.stat();
    final text = await _file.readAsString();
    final etag = sha256.convert(utf8.encode(text)).toString();
    return etag != _lastReadEtag ||
        stat.modified != _lastReadModified ||
        stat.size != _lastReadLength;
  }
}
