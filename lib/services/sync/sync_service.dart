import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/device_clock.dart';
import '../../core/hlc.dart';
import '../app_data_service.dart';
import 'hub_discovery.dart';
import 'lan_sync_client.dart';
import 'sync_document.dart';
import 'sync_merger.dart';
import 'sync_progress.dart';
import 'sync_settings.dart';

final syncServiceProvider = Provider<SyncService>(
  (ref) => SyncService(
    client: ref.read(lanSyncClientProvider),
    data: ref.read(appDataServiceProvider),
    settingsStore: ref.read(syncSettingsStoreProvider),
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
  bool get retriable => code == 'unreachable' || code == 'timeout';

  /// The pairing itself is broken — the phone has to scan a new QR.
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
    Future<HubAddress?> Function()? discover,
    this.discoveryTimeout = const Duration(seconds: 3),
  }) : _discover = discover ?? discoverHub;

  final LanSyncClient client;
  final AppDataService data;
  final SyncSettingsStore settingsStore;
  final DeviceClock deviceClock;
  final Duration discoveryTimeout;
  final Future<HubAddress?> Function() _discover;

  Future<SyncOutcome> syncNow({
    SyncMode mode = SyncMode.merge,
    SyncProgressController? progress,
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
        await settingsStore.save(settings);
        progress?.stage(SyncStage.connecting);
        response = await client.sync(settings, payload, mode: mode.wire, progress: progress);
      }

      if (progress?.isCancelled ?? false) {
        return SyncCancelled(hubMayHaveChanged: progress!.value.hubMayHaveChanged);
      }
      progress?.stage(SyncStage.applying);
      final document = SyncDocument.fromJson(response.document, strict: true);
      await _observeClocks(document);
      progress?.stage(SyncStage.saving);
      await data.importDocument(document);
      await settingsStore.save(settings.copyWith(lastSyncAt: DateTime.now().toUtc()));
      progress?.finish(response.summary);
      return SyncApplied(response.summary, response.warnings);
    } on SyncHttpException catch (error) {
      if (error.code == 'cancelled') {
        return SyncCancelled(hubMayHaveChanged: progress?.value.hubMayHaveChanged ?? false);
      }
      final message = syncErrorMessage(error.code, fallback: error.message);
      progress?.fail(error.code, message);
      if (error.code == 'purged_before') return SyncNeedsReplace(message);
      return SyncFailed(error.code, message);
    } on UnsupportedSchemaException catch (error) {
      final message = syncErrorMessage('upgrade_required');
      progress?.fail('upgrade_required', message);
      return SyncFailed('upgrade_required', '$message（$error）');
    } on FormatException catch (error) {
      final message = syncErrorMessage('corrupt');
      progress?.fail('corrupt', '$message: ${error.message}');
      return SyncFailed('corrupt', message);
    }
  }

  /// Applies a document received out of band (QR or file) using the same merge
  /// rules the hub uses.
  Future<SyncApplied> applyReceived(
    Map<String, dynamic> json, {
    SyncProgressController? progress,
  }) async {
    progress?.stage(SyncStage.applying);
    final incoming = SyncDocument.fromJson(json, strict: true);
    final local = await data.exportDocument();
    final merged = SyncMerger.merge(local, incoming);
    await _observeClocks(merged.document);
    progress?.stage(SyncStage.saving);
    await data.importDocument(merged.document);
    final summary = merged.summaryAgainst(local);
    progress?.finish(summary);
    return SyncApplied(summary, merged.warnings);
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
  /// local edit sorts after the records that just arrived.
  Future<void> _observeClocks(SyncDocument doc) async {
    var best = Hlc.migrated;
    void consider(Hlc c) {
      if (c.compareTo(best) > 0) best = c;
    }

    for (final t in doc.taskMaster.tasks) {
      consider(t.meta.clock);
    }
    for (final t in doc.taskMaster.deletedTasks) {
      consider(t.meta.clock);
    }
    for (final c in [
      ...doc.taskMaster.mustDoCategories,
      ...doc.taskMaster.wantToDoCategories,
    ]) {
      consider(c.meta.clock);
    }
    for (final t in [
      ...doc.taskMaster.deletedMustDoCategories,
      ...doc.taskMaster.deletedWantToDoCategories,
    ]) {
      consider(t.meta.clock);
    }
    for (final p in doc.dailyPlan.plans) {
      consider(p.meta.clock);
    }
    for (final s in doc.dailyPlan.slots) {
      consider(s.meta.clock);
    }
    for (final a in doc.dailyPlan.assignments) {
      consider(a.meta.clock);
    }
    for (final t in [
      ...doc.dailyPlan.deletedPlans,
      ...doc.dailyPlan.deletedSlots,
      ...doc.dailyPlan.deletedAssignments,
    ]) {
      consider(t.meta.clock);
    }
    consider(doc.taskMaster.settingsMeta.clock);
    if (!best.isMigrated) await deviceClock.observe(best);
  }
}
