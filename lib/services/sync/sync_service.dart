import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/device_clock.dart';
import '../app_data_service.dart';
import 'conflict_record.dart';
import 'conflict_resolver.dart';
import 'document_clocks.dart';
import 'hub_discovery.dart';
import 'lan_sync_client.dart';
import 'sync_backup_store.dart';
import 'sync_document.dart';
import 'sync_merger.dart';
import 'sync_progress.dart';
import 'sync_settings.dart';

final syncServiceProvider = Provider<SyncService>(
  (ref) => SyncService(
    client: ref.read(lanSyncClientProvider),
    data: ref.read(appDataServiceProvider),
    settingsStore: ref.read(syncSettingsStoreProvider),
    backupStore: ref.read(syncBackupStoreProvider),
    deviceClock: ref.read(deviceClockProvider),
  ),
);

enum SyncMode { merge, takeHub, takePhone }

extension SyncModeWire on SyncMode {
  /// The `mode` query value the hub understands.
  String get wire => switch (this) {
    SyncMode.merge => 'merge',
    SyncMode.takeHub => 'take_hub',
    SyncMode.takePhone => 'take_phone',
  };
}

sealed class SyncOutcome {
  const SyncOutcome();
}

class SyncApplied extends SyncOutcome {
  const SyncApplied(this.summary, this.warnings);

  final SyncSummary summary;
  final List<String> warnings;
}

/// The hub purged tombstones this phone never saw: merging would resurrect
/// them, so the user has to pick a side (`take_phone` or `take_hub`).
class SyncNeedsReplace extends SyncOutcome {
  const SyncNeedsReplace(this.message);

  final String message;
}

class SyncCancelled extends SyncOutcome {
  const SyncCancelled({required this.hubMayHaveChanged});

  /// True when the cancel landed after the document was fully sent: the hub
  /// may already hold the merge even though this phone never applied it.
  final bool hubMayHaveChanged;
}

class SyncFailed extends SyncOutcome {
  const SyncFailed(this.code, this.message);

  final String code;
  final String message;

  /// Transport trouble; the same request may well work in a moment.
  ///
  /// Derived from the same set [SyncHttpException.retriable] uses, so the
  /// panel's retry button and the client's own judgement can never drift
  /// apart.
  bool get retriable => retriableSyncCodes.contains(code);

  /// The pairing itself is broken — the phone has to scan a new QR.
  ///
  /// `bad_timestamp` deliberately stays out: a stored sync stamp the hub
  /// cannot parse is fixed by clearing that stamp, and telling the user to
  /// re-pair would be asking them to redo something that is not broken.
  bool get needsRepair => const {
    'unauthorized',
    'certificate',
    'not_paired',
    'pairing_failed',
    'pairing_code_expired',
    'too_many_attempts',
  }.contains(code);
}

/// One tap = export → POST /sync → replace local state with the hub's merged
/// result.
class SyncService {
  SyncService({
    required this.client,
    required this.data,
    required this.settingsStore,
    required this.deviceClock,
    SyncBackupStore? backupStore,
    Future<HubAddress?> Function()? discover,
    this.discoveryTimeout = const Duration(seconds: 3),
  }) : backupStore = backupStore ?? SyncBackupStore(),
       _discover = discover ?? discoverHub;

  final LanSyncClient client;
  final AppDataService data;
  final SyncSettingsStore settingsStore;
  final SyncBackupStore backupStore;
  final DeviceClock deviceClock;
  final Duration discoveryTimeout;
  final Future<HubAddress?> Function() _discover;

  /// The sync currently running, if any. Two syncs at once would export the
  /// same document twice and race each other into `importDocument`; the
  /// second caller is told the phone is busy instead.
  Future<SyncOutcome>? _inFlight;

  bool get isSyncing => _inFlight != null;

  Future<SyncOutcome> syncNow({
    SyncMode mode = SyncMode.merge,
    SyncProgressController? progress,
  }) {
    if (_inFlight != null) {
      return Future<SyncOutcome>.value(
        SyncFailed('busy', syncErrorMessage('busy')),
      );
    }
    final running = _syncNow(mode: mode, progress: progress);
    _inFlight = running;
    return running.whenComplete(() => _inFlight = null);
  }

  Future<SyncOutcome> _syncNow({
    required SyncMode mode,
    required SyncProgressController? progress,
  }) async {
    var settings = await settingsStore.load();
    if (!settings.isPaired) {
      const code = 'not_paired';
      progress?.fail(code, syncErrorMessage(code));
      return const SyncFailed(code, 'PC とペアリングされていません。設定の「PC とペアリング」から QR を読み取ってください。');
    }
    progress?.start(SyncKind.lan);
    try {
      final exported = await data.exportDocument();
      final payload = SyncDocument(
        exportedAt: exported.exportedAt,
        deviceId: exported.deviceId,
        // The hub rejects an unparsable lastSyncAt with 400 bad_timestamp, and
        // reads an offset-less one as its own local time; SyncDocument.toJson
        // always writes UTC with `Z`.
        lastSyncAt: settings.lastSyncAt,
        taskMaster: exported.taskMaster,
        dailyPlan: exported.dailyPlan,
        // Sent, not dropped: a conflict this phone resolved while offline only
        // reaches the PC — and the other devices — as a conflict record.
        conflicts: exported.conflicts,
      ).toJson();

      SyncResponse response;
      try {
        response = await client.sync(settings, payload, mode: mode.wire, progress: progress);
      } on SyncHttpException catch (error) {
        // Only a dead address is worth a second look: everything else is a
        // decision the hub already made about this payload.
        if (error.code != 'unreachable') rethrow;
        final found = await _discoverTimeBoxed();
        if (found == null || (found.host == settings.host && found.port == settings.port)) {
          rethrow;
        }
        // The hub moved (DHCP, a new Wi-Fi); the pin and the token still hold.
        settings = settings.copyWith(host: found.host, port: found.port);
        progress?.stage(SyncStage.connecting);
        response = await client.sync(settings, payload, mode: mode.wire, progress: progress);
        // Only now is the new address worth remembering: writing it before the
        // retry would replace a merely-unreachable address with a guess that
        // may itself be wrong, and the user would be stuck editing it by hand.
        await settingsStore.save(settings);
      }

      if (progress?.isCancelled ?? false) {
        return SyncCancelled(hubMayHaveChanged: progress!.value.hubMayHaveChanged);
      }
      progress?.stage(SyncStage.applying);
      final document = SyncDocument.fromJson(response.document, strict: true);
      await _observeClocks(document);
      progress?.stage(SyncStage.saving);
      // A replace throws away whichever side lost. Snapshot first so the user
      // has a way back that does not depend on the hub still holding it.
      if (mode != SyncMode.merge) await _snapshotBeforeReplace();
      await data.importDocument(document);
      // The hub's own stamp, not this phone's clock: a phone whose clock runs
      // fast would otherwise record a lastSyncAt in the hub's future and make
      // the next delta look empty.
      await settingsStore.save(
        settings.copyWith(lastSyncAt: document.lastSyncAt ?? DateTime.now().toUtc()),
      );
      progress?.finish(response.summary);
      return SyncApplied(response.summary, response.warnings);
    } catch (error) {
      return _mapFailure(error, progress);
    }
  }

  /// Turns anything thrown while talking to the hub or applying its answer
  /// into the outcome the UI renders. Shared by [syncNow] and [applyReceived]
  /// so a QR import and a LAN sync explain the same failure the same way.
  SyncOutcome _mapFailure(Object error, SyncProgressController? progress) {
    if (error is SyncHttpException) {
      if (error.code == 'cancelled') {
        return SyncCancelled(hubMayHaveChanged: progress?.value.hubMayHaveChanged ?? false);
      }
      // The hub's own `message` is English and written for logs; it belongs in
      // the failure detail, never in what the panel shows.
      final message = syncErrorMessage(error.code);
      progress?.fail(error.code, message);
      if (error.code == 'purged_before') return SyncNeedsReplace(message);
      return SyncFailed(error.code, _withDetail(message, error.message));
    }
    if (error is UnsupportedSchemaException) {
      final message = syncErrorMessage('upgrade_required');
      progress?.fail('upgrade_required', message);
      return SyncFailed('upgrade_required', '$message（$error）');
    }
    if (error is FormatException) {
      final message = syncErrorMessage('corrupt');
      progress?.fail('corrupt', message);
      return SyncFailed('corrupt', _withDetail(message, error.message));
    }
    throw error;
  }

  static String _withDetail(String message, String detail) =>
      detail.isEmpty ? message : '$message（$detail）';

  /// Keeps one copy of everything this phone holds, so a replace the user
  /// regrets is one tap away from being undone.
  Future<void> _snapshotBeforeReplace() async =>
      backupStore.save(await data.exportAll());

  /// True when [restoreBackup] has something to put back.
  Future<bool> get hasBackup => backupStore.exists();

  /// Puts back the snapshot taken before the last replace. Returns false when
  /// there is no usable snapshot, in which case nothing is touched.
  Future<bool> restoreBackup() async {
    final json = await backupStore.load();
    if (json == null) return false;
    final SyncDocument document;
    try {
      document = SyncDocument.fromJson(json, strict: true);
    } on FormatException {
      return false;
    } on UnsupportedSchemaException {
      return false;
    }
    await data.importDocument(document);
    // One shot: leaving it in place would let a second tap silently undo work
    // done after the restore.
    await backupStore.clear();
    return true;
  }

  /// Applies a document received out of band (QR or file) using the same merge
  /// rules the hub uses.
  /// Returns the same [SyncOutcome] a LAN sync does: a QR or a file can carry
  /// a document this build cannot read, and the caller needs to say so in the
  /// same words the panel already uses.
  Future<SyncOutcome> applyReceived(
    Map<String, dynamic> json, {
    SyncProgressController? progress,
  }) async {
    try {
      progress?.stage(SyncStage.applying);
      final incoming = SyncDocument.fromJson(json, strict: true);
      final local = await data.exportDocument();
      final settings = await settingsStore.load();
      final merged = SyncMerger.merge(
        local,
        incoming,
        // The agreement point is the last successful sync with the hub. Null
        // before the first one, which switches detection off entirely.
        lastAgreedAt: settings.lastSyncAt,
        detectedBy: deviceClock.deviceId,
        detectedAt: DateTime.now().toUtc(),
      );
      await _observeClocks(merged.document);
      progress?.stage(SyncStage.saving);
      await data.importDocument(merged.document);
      final summary = merged.summaryAgainst(local);
      progress?.finish(summary);
      return SyncApplied(summary, merged.warnings);
    } catch (error) {
      return _mapFailure(error, progress);
    }
  }

  /// Resolves one recorded conflict by adopting a side, or by closing the
  /// record and leaving the current state alone.
  ///
  /// Written as an ordinary local edit with this device's own clock, so it
  /// works offline and propagates on the next sync — and, in hub mode, is
  /// simply another document write.
  Future<ConflictResolutionResult> resolveConflict(
    String id,
    ConflictAdoption adopt,
  ) => _resolve(adopt, (c) => c.id == id, requireOpen: id);

  /// The same decision for every open record, optionally of one entity type.
  Future<ConflictResolutionResult> resolveAll(
    ConflictAdoption adopt, {
    String? entityType,
  }) => _resolve(adopt, (c) => entityType == null || c.entityType == entityType);

  /// Read, decide and write as one step.
  ///
  /// The decision is measured against the live entity — adopting the version
  /// that is already stored writes nothing, and a purged entity is refused — so
  /// it has to be taken on the document that is about to be written, not on a
  /// copy read some milliseconds earlier. Going through
  /// [AppDataService.updateDocument] is what makes that true: on the hub's file
  /// the whole thing runs under the cross-process lock, and in hub mode it
  /// folds into the snapshot being pushed.
  ///
  /// A throw from [applyConflictResolutions] propagates out of the update, so a
  /// refused resolution writes nothing at all — including the records it had
  /// already stamped before reaching the one it could not apply.
  Future<ConflictResolutionResult> _resolve(
    ConflictAdoption adopt,
    bool Function(ConflictRecord) where, {
    String? requireOpen,
  }) async {
    late ConflictResolutionResult result;
    await data.updateDocument((current) async {
      if (requireOpen != null) {
        // Checked on the document that is about to be written, not on one read
        // beforehand: a record another device resolved in between must be
        // refused rather than decided twice.
        final record = current.conflicts.where((c) => c.id == requireOpen).firstOrNull;
        if (record == null) {
          throw const ConflictResolutionException('この競合は見つかりませんでした。');
        }
        if (!record.isOpen) {
          throw const ConflictResolutionException('この競合はすでに解決済みです。');
        }
      }
      result = await applyConflictResolutions(
        current,
        adopt: adopt,
        where: where,
        nextClock: deviceClock.next,
        resolvedBy: deviceClock.deviceId,
      );
      // Nothing was open to decide: leave the store alone rather than rewrite
      // it with a document identical to the one just read.
      return result.resolved > 0 ? result.document : null;
    });
    return result;
  }

  /// mDNS is a fallback, never a gate: a slow or silent network must not hold
  /// the sync open, so the lookup gets a fixed budget and then gives up.
  Future<HubAddress?> _discoverTimeBoxed() async {
    try {
      // `.then` first: an injected lookup may hand back a non-nullable future,
      // and `timeout`'s `onTimeout` is checked against the *runtime* type.
      return await _discover()
          .then<HubAddress?>((found) => found)
          .timeout(discoveryTimeout, onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  /// Pulls this device's clock up to anything the hub has seen, so the next
  /// local edit sorts after the records that just arrived. The scan itself is
  /// shared with the hub-mode store (`document_clocks.dart`) so the two paths
  /// can never disagree about which lists count.
  Future<void> _observeClocks(SyncDocument doc) =>
      observeDocumentClocks(deviceClock, doc);
}
