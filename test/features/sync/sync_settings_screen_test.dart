import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/sync/presentation/sync_settings_screen.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/sync/sync_backup_store.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:frelocator/services/sync/sync_progress.dart';
import 'package:frelocator/services/sync/sync_service.dart';
import 'package:frelocator/services/sync/sync_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_container.dart';

/// Stands in for the real service so a test can hold a sync open, or finish it
/// on demand, without a hub on the other end.
class _FakeSyncService implements SyncService {
  final Completer<SyncOutcome> pending = Completer<SyncOutcome>();

  int syncCalls = 0;
  SyncMode? lastMode;
  SyncProgressController? lastProgress;

  @override
  Future<SyncOutcome> syncNow({
    SyncMode mode = SyncMode.merge,
    SyncProgressController? progress,
  }) {
    syncCalls += 1;
    lastMode = mode;
    lastProgress = progress;
    progress?.start(SyncKind.lan);
    return pending.future;
  }

  @override
  Future<bool> get hasBackup async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

Future<void> _pumpScreen(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SyncSettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

SyncSettings _paired() => SyncSettings(
  host: '192.168.1.10',
  port: 47820,
  fingerprint: 'AB' * 32,
  token: 't' * 64,
  hubDeviceId: 'hub-macos',
  lastSyncAt: DateTime.utc(2026, 9, 9, 1),
);

String _backupJson() => jsonEncode(
  SyncDocument(
    exportedAt: DateTime.utc(2026, 9, 9),
    deviceId: 'test-1',
    taskMaster: TaskMasterStateData.initial(),
    dailyPlan: DailyPlanStateData.initial(),
  ).toJson(),
);

void main() {
  testWidgets('unpaired shows the pairing CTA and hides 今すぐ同期', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = await testContainer();
    await _pumpScreen(tester, container);

    expect(find.text('未ペアリング'), findsOneWidget);
    expect(find.text('PC とペアリング'), findsOneWidget);
    expect(find.text('今すぐ同期'), findsNothing);
    expect(find.text('ペアリングを解除'), findsNothing);
    expect(find.text('QR で受け取る'), findsOneWidget);
    expect(find.text('PC へ書き出す'), findsOneWidget);
    expect(find.text('直前の同期前に戻す'), findsNothing);
  });

  testWidgets('paired shows the host, the last sync and the sync button', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SyncSettingsStore().save(_paired());
    final container = await testContainer();
    await _pumpScreen(tester, container);

    expect(find.textContaining('192.168.1.10:47820'), findsOneWidget);
    expect(find.textContaining('hub-macos'), findsOneWidget);
    expect(find.text('今すぐ同期'), findsOneWidget);
    expect(find.text('ペアリングを解除'), findsOneWidget);
    expect(find.textContaining('2026/09/09'), findsOneWidget);
  });

  testWidgets('unpairing clears the stored connection', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SyncSettingsStore().save(_paired());
    final container = await testContainer();
    await _pumpScreen(tester, container);

    await tester.tap(find.text('ペアリングを解除'));
    await tester.pumpAndSettle();

    expect(find.text('未ペアリング'), findsOneWidget);
    expect((await SyncSettingsStore().load()).isPaired, isFalse);
  });

  testWidgets('a running sync opens the panel and disables 今すぐ同期', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SyncSettingsStore().save(_paired());
    final fake = _FakeSyncService();
    final container = await testContainer(
      overrides: <Override>[syncServiceProvider.overrideWithValue(fake)],
    );
    await _pumpScreen(tester, container);

    await tester.tap(find.text('今すぐ同期'));
    // Not `pumpAndSettle`: an in-flight sync shows an indeterminate progress
    // bar, which never stops animating.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(fake.syncCalls, 1);
    expect(fake.lastMode, SyncMode.merge);
    expect(find.text('接続中'), findsOneWidget);
    expect(find.text('キャンセル'), findsOneWidget);
    // The tile behind the sheet is greyed out rather than silently answering
    // `busy` when it is tapped again.
    expect(tester.widget<ListTile>(find.widgetWithText(ListTile, '今すぐ同期')).enabled, isFalse);

    fake.lastProgress!.finish(
      const SyncSummary(added: 1, updated: 2, deleted: 3, warnings: 0, removed: 4),
    );
    fake.pending.complete(
      const SyncApplied(
        SyncSummary(added: 1, updated: 2, deleted: 3, warnings: 0, removed: 4),
        <String>[],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('追加 1 / 更新 2 / 削除 3 / 消去 4 / 警告 0'), findsOneWidget);
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(find.widgetWithText(ListTile, '今すぐ同期')).enabled, isTrue);
  });

  testWidgets('a stored backup offers 直前の同期前に戻す', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SyncBackupStore.key: _backupJson(),
    });
    await SyncSettingsStore().save(_paired());
    final container = await testContainer();
    await _pumpScreen(tester, container);

    final restore = find.text('直前の同期前に戻す');
    await tester.scrollUntilVisible(restore, 200);
    expect(restore, findsOneWidget);

    await tester.ensureVisible(restore);
    await tester.pumpAndSettle();
    await tester.tap(restore);
    await tester.pumpAndSettle();

    expect(find.text('同期前の状態に戻しました'), findsOneWidget);
    expect(await SyncBackupStore().exists(), isFalse);
    // One shot: the snapshot is consumed, so the button goes away.
    expect(find.text('直前の同期前に戻す'), findsNothing);
  });

  testWidgets('macOS gets the Claude Code (MCP) guide', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = await testContainer();
    await _pumpScreen(tester, container);

    await tester.scrollUntilVisible(find.text('Claude Code（MCP）と連携'), 200);
    expect(find.text('Claude Code（MCP）と連携'), findsOneWidget);
    expect(find.textContaining('npm install && npm run build'), findsOneWidget);
    expect(find.textContaining('sync_status'), findsWidgets);
  }, skip: !Platform.isMacOS);
}
