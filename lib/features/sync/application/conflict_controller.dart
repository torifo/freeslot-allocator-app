import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/app_data_service.dart';
import '../../../services/hub_mode/hub_mode.dart';
import '../../../services/sync/conflict_record.dart';
import '../../../services/sync/conflict_resolver.dart';
import '../../../services/sync/sync_service.dart';
import '../../daily_plan/application/daily_plan_controller.dart';
import '../../task_master/application/task_master_controller.dart';

/// Non-null only in the browser the hub itself serves. A provider rather than a
/// direct `readHubMode()` call so a widget test can pretend to be that browser.
final hubModeProvider = Provider<HubMode?>((ref) => readHubMode());

/// This browser's own web id, for telling 「この端末の版」 from 「ブラウザ版」.
final webIdProvider = Provider<String?>((ref) => readWebId());

/// Every conflict record the document holds, open and resolved alike.
///
/// Reads through [AppDataService], so it works unchanged on the phone (records
/// stored beside the payload) and in hub mode (records read live from the hub's
/// document).
final conflictControllerProvider =
    AsyncNotifierProvider<ConflictController, List<ConflictRecord>>(
      ConflictController.new,
    );

class ConflictController extends AsyncNotifier<List<ConflictRecord>> {
  @override
  Future<List<ConflictRecord>> build() async =>
      (await ref.read(appDataServiceProvider).exportDocument()).conflicts;

  Future<ConflictResolutionResult> resolve(String id, ConflictAdoption adopt) =>
      _run(() => ref.read(syncServiceProvider).resolveConflict(id, adopt));

  Future<ConflictResolutionResult> resolveAll(
    ConflictAdoption adopt, {
    String? entityType,
  }) => _run(
    () => ref.read(syncServiceProvider).resolveAll(adopt, entityType: entityType),
  );

  Future<ConflictResolutionResult> _run(
    Future<ConflictResolutionResult> Function() body,
  ) async {
    final result = await body();
    // The result already carries the document that was just written, so the
    // list refreshes without a second read.
    state = AsyncData<List<ConflictRecord>>(result.document.conflicts);
    if (result.wrote > 0) {
      // Adopting a side is an ordinary edit: the screens showing that entity
      // are now behind it.
      ref.invalidate(taskMasterControllerProvider);
      ref.invalidate(dailyPlanControllerProvider);
    }
    return result;
  }
}

/// Still waiting for the user.
List<ConflictRecord> openConflicts(List<ConflictRecord> all) =>
    all.where((c) => c.isOpen).toList();

/// Decided, but still on file. Tombstoned records are housekeeping and are not
/// shown at all.
List<ConflictRecord> resolvedConflicts(List<ConflictRecord> all) =>
    all.where((c) => !c.isOpen && !c.meta.isDeleted).toList();

/// Japanese names for the entity kinds this build can draw; anything else keeps
/// the raw type, which a newer app may have written.
const Map<String, String> conflictEntityLabels = <String, String>{
  'task': 'タスク',
  'category': 'カテゴリ',
  'plan': '日次プラン',
  'slot': '空き時間',
  'assignment': '割り当て',
  'settings': '設定',
};

/// One line naming the thing in conflict, e.g. `タスク「確定申告の書類を集める」`.
/// Mirrors the hub's `list_conflicts` label so both surfaces read the same.
String conflictLabel(ConflictRecord record) {
  final noun = conflictEntityLabels[record.entityType] ?? record.entityType;
  if (record.entityType == 'settings') return noun;
  String? named(ConflictSide side) {
    for (final key in const <String>['title', 'name', 'date']) {
      final value = side.snapshot[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return null;
  }

  // A tombstone carries no fields at all, so the other side is the only place
  // the name survives.
  final name = named(record.winner) ?? named(record.loser);
  return name == null ? '$noun（${record.entityId}）' : '$noun「$name」';
}

/// The two versions a record holds, named the way the user reads them: 「PC 版」
/// covers both the MCP hub and the browser it serves, 「スマホ版」 is the phone.
/// Derived from the recorded `side`, which itself comes from the HLC device id,
/// so it does not matter which side ran the merge.
ConflictSide conflictPcSide(ConflictRecord record) =>
    isPcSide(record.winner.side) ? record.winner : record.loser;

ConflictSide conflictPhoneSide(ConflictRecord record) =>
    isPcSide(record.winner.side) ? record.loser : record.winner;

/// What to call one side on screen.
///
/// In hub mode this browser *is* the PC, so the hub side has to say which half
/// of the PC it means; everywhere else 「PC 版」 is unambiguous and shorter.
String conflictSideLabel(
  ConflictSide side, {
  required bool hubMode,
  String? webId,
}) => conflictDeviceLabel(side.deviceId, hubMode: hubMode, webId: webId);

String conflictDeviceLabel(
  String deviceId, {
  required bool hubMode,
  String? webId,
}) {
  if (deviceId.startsWith('hub-')) return hubMode ? 'PC（MCP）版' : 'PC 版';
  if (deviceId.startsWith('web-')) {
    return webId != null && deviceId == 'web-$webId' ? 'この端末の版' : 'ブラウザ版';
  }
  return 'スマホ版';
}

/// Japanese field names for the comparison table. An unknown key is shown as it
/// is rather than hidden: a newer app's field is still something the user can
/// read and compare.
const Map<String, String> conflictFieldLabels = <String, String>{
  'title': 'タイトル',
  'name': '名前',
  'memo': 'メモ',
  'priority': '優先度',
  'kind': '種別',
  'categoryId': 'カテゴリ',
  'categoryName': 'カテゴリ名',
  'estimatedMinutes': '見積り（分）',
  'createdAt': '作成日時',
  'date': '日付',
  'dailyPlanId': '日次プラン',
  'slotId': '空き時間',
  'taskId': 'タスク',
  'taskTitle': 'タスク名',
  'taskKind': 'タスク種別',
  'startAt': '開始',
  'endAt': '終了',
  'label': 'ラベル',
  'sortOrder': '並び順',
  'shareCategories': 'カテゴリ共有',
  'deletedAt': '削除',
};

String conflictFieldLabel(String field) => conflictFieldLabels[field] ?? field;
