import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/sync/application/sync_in_flight.dart';
import 'package:frelocator/features/sync/presentation/sync_progress_panel.dart';
import 'package:frelocator/features/sync/presentation/sync_replace_dialog.dart';
import 'package:frelocator/features/sync/presentation/sync_settings_screen.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/sync/lan_sync_types.dart';
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
  _FakeSyncService({this.outcomes = const <SyncOutcome>[]});

  /// Answers for the successive `syncNow` calls; when the list runs out the
  /// call parks on [pending] instead, so a test can hold the sync open.
  final List<SyncOutcome> outcomes;

  final Completer<SyncOutcome> pending = Completer<SyncOutcome>();

  int syncCalls = 0;
  SyncMode? lastMode;
  final List<SyncMode> modes = <SyncMode>[];
  SyncProgressController? lastProgress;

  @override
  Future<SyncOutcome> syncNow({
    SyncMode mode = SyncMode.merge,
    SyncProgressController? progress,
  }) async {
    syncCalls += 1;
    lastMode = mode;
    modes.add(mode);
    lastProgress = progress;
    // The real client reaches the network before it can report anything, so it
    // never starts the progress in the same turn it was called. The `await`
    // reproduces that: a screen that leaned on `syncNow` to start the progress
    // would show the sheet on 「待機中」 with a 閉じる that abandons the run.
    await Future<void>.delayed(Duration.zero);
    progress?.start(SyncKind.lan);
    if (syncCalls > outcomes.length) return pending.future;
    final outcome = outcomes[syncCalls - 1];
    // The real service leaves the panel on a terminal stage before it answers;
    // without that the indeterminate bar keeps animating and nothing settles.
    switch (outcome) {
      case SyncApplied(:final summary):
        progress?.finish(summary);
      case SyncFailed(:final code, :final message):
        progress?.fail(code, message);
      case SyncCancelled():
        progress?.cancel();
      case SyncNeedsReplace():
        break; // the panel is about to be replaced by the question
    }
    return outcome;
  }

  @override
  Future<bool> get hasBackup async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

/// Throws something `SyncService` never promises, to prove the screen's
/// catch-all rather than an uncaught async error in a test.
class _ThrowingSyncService implements SyncService {
  @override
  Future<SyncOutcome> syncNow({
    SyncMode mode = SyncMode.merge,
    SyncProgressController? progress,
  }) async {
    progress?.start(SyncKind.lan);
    throw StateError('the platform channel went away');
  }

  @override
  Future<bool> get hasBackup async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

/// Accepts whatever `applyReceived` is handed and reports a fixed summary.
class _ApplyingSyncService implements SyncService {
  int received = 0;

  static const _summary = SyncSummary(
    added: 2,
    updated: 0,
    deleted: 0,
    warnings: 0,
  );

  @override
  Future<SyncOutcome> applyReceived(
    Map<String, dynamic> json, {
    SyncMode mode = SyncMode.merge,
    SyncProgressController? progress,
  }) async {
    received += 1;
    progress?.finish(_summary);
    return const SyncApplied(_summary, <String>[]);
  }

  @override
  Future<bool> get hasBackup async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

/// Stands in for the open dialog: answers with one path, or null for a cancel.
class _FakeOpenFilePicker extends FilePicker {
  _FakeOpenFilePicker(this.answer);

  final String? answer;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    dynamic onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    final path = answer;
    if (path == null) return null;
    return FilePickerResult(<PlatformFile>[
      PlatformFile(path: path, name: path.split('/').last, size: 0),
    ]);
  }
}

/// A picker that refuses, the way the platform does for an unusable choice.
class _ThrowingOpenFilePicker extends FilePicker {
  _ThrowingOpenFilePicker(this.error);

  final Object error;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    dynamic onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => throw error;
}

/// Installs a fake picker for one test and puts the previous one back after.
///
/// `FilePicker.platform` is a global: a test that left its fake behind would
/// hand it to every later test in the same file — and to any test file that
/// shares the isolate. Reading it before anything has set it throws, so the
/// "previous" is simply absent on the first use.
void _usePicker(FilePicker picker) {
  FilePicker? previous;
  try {
    previous = FilePicker.platform;
  } on Error {
    previous = null;
  }
  FilePicker.platform = picker;
  addTearDown(() {
    if (previous != null) FilePicker.platform = previous;
  });
}

/// A first route to push the sync screen from, so a test can pop it while a
/// sync is still running.
class _Launcher extends StatelessWidget {
  const _Launcher();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => Navigator.of(context).pushNamed('/sync'),
        child: const Text('open'),
      ),
    ),
  );
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

    // Confirmed first: an accidental tap must not cost the connection.
    expect(find.textContaining('QR を読み直して'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect((await SyncSettingsStore().load()).isPaired, isTrue);

    await tester.tap(find.text('ペアリングを解除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('解除'));
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
    // The restore throws away everything done since the sync, so it asks.
    expect(find.text('同期前に戻す'), findsOneWidget);
    await tester.tap(find.text('戻す'));
    await tester.pumpAndSettle();

    expect(find.text('同期前の状態に戻しました'), findsOneWidget);
    expect(await SyncBackupStore().exists(), isFalse);
    // One shot: the snapshot is consumed, so the button goes away.
    expect(find.text('直前の同期前に戻す'), findsNothing);
  });

  testWidgets('leaving the screen mid-sync still clears the in-flight flag', (tester) async {
    // `app.dart` holds its foreground reload back while a sync is in flight. If
    // the flag is never lowered — because the screen was popped before the sync
    // finished — the app stops reloading for the rest of its life.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SyncSettingsStore().save(_paired());
    final fake = _FakeSyncService();
    final container = await testContainer(
      overrides: <Override>[syncServiceProvider.overrideWithValue(fake)],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: const _Launcher(),
          routes: <String, WidgetBuilder>{
            '/sync': (_) => const SyncSettingsScreen(),
          },
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('今すぐ同期'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(syncInFlightProvider), isTrue);

    // The route goes away under the running sync (a deep link, a back gesture
    // the OS honoured, anything that is not the sheet's own 閉じる).
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .popUntil((Route<dynamic> route) => route.isFirst);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('今すぐ同期'), findsNothing);
    fake.pending.complete(const SyncCancelled(hubMayHaveChanged: false));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(container.read(syncInFlightProvider), isFalse);
  });

  testWidgets('the sheet is never on 待機中 with a 閉じる that abandons the run', (tester) async {
    // The fake only starts the progress after a microtask, like the real
    // client, which reaches the network first.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SyncSettingsStore().save(_paired());
    final fake = _FakeSyncService();
    final container = await testContainer(
      overrides: <Override>[syncServiceProvider.overrideWithValue(fake)],
    );
    await _pumpScreen(tester, container);

    await tester.tap(find.text('今すぐ同期'));
    // One frame only: the sheet is on screen before `syncNow` has come back.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('待機中'), findsNothing);
    expect(find.text('閉じる'), findsNothing);
    expect(find.text('キャンセル'), findsOneWidget);

    fake.lastProgress!.cancel();
    fake.pending.complete(const SyncCancelled(hubMayHaveChanged: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
  });

  testWidgets('purged_before asks, and the answer re-runs the sync in that mode', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SyncSettingsStore().save(_paired());
    final fake = _FakeSyncService(
      outcomes: <SyncOutcome>[
        SyncNeedsReplace(syncErrorMessage('purged_before')),
        const SyncApplied(
          SyncSummary(added: 5, updated: 0, deleted: 0, warnings: 0),
          <String>[],
        ),
      ],
    );
    final container = await testContainer(
      overrides: <Override>[syncServiceProvider.overrideWithValue(fake)],
    );
    await _pumpScreen(tester, container);

    await tester.tap(find.text('今すぐ同期'));
    // Explicit frames while the panel's indeterminate bar is still sweeping.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // The sheet steps aside for the question: this outcome is not a result.
    expect(find.byType(SyncReplaceDialog), findsOneWidget);
    expect(find.textContaining('どちらのデータを正にする'), findsOneWidget);

    await tester.tap(find.text('PC の状態で置き換える'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(fake.modes, <SyncMode>[SyncMode.merge, SyncMode.takeHub]);
    expect(find.text('追加 5 / 更新 0 / 削除 0 / 消去 0 / 警告 0'), findsOneWidget);
    expect(container.read(syncInFlightProvider), isFalse);

    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();
  });

  testWidgets('an error nothing mapped still lands on a Japanese failure', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SyncSettingsStore().save(_paired());
    final fake = _ThrowingSyncService();
    final container = await testContainer(
      overrides: <Override>[syncServiceProvider.overrideWithValue(fake)],
    );
    await _pumpScreen(tester, container);

    await tester.tap(find.text('今すぐ同期'));
    await tester.pumpAndSettle();

    expect(find.text('失敗'), findsOneWidget);
    expect(find.text(syncErrorMessage('unknown')), findsOneWidget);
    expect(container.read(syncInFlightProvider), isFalse);
  });

  testWidgets('接続先を手入力 refuses an empty host and an impossible port', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SyncSettingsStore().save(_paired());
    final container = await testContainer();
    await _pumpScreen(tester, container);

    await tester.tap(find.text('接続先を手入力'));
    await tester.pumpAndSettle();

    final hostField = find.byType(TextField).at(0);
    final portField = find.byType(TextField).at(1);
    final save = find.widgetWithText(FilledButton, '保存');

    await tester.enterText(hostField, '');
    await tester.pumpAndSettle();
    expect(find.text('ホストを入力してください'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.enterText(hostField, '192.168.1.99');
    await tester.enterText(portField, '70000');
    await tester.pumpAndSettle();
    expect(find.text('ポートは 1〜65535 の数字です'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.enterText(portField, '0');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    // A pasted address with a stray space is trimmed, not refused (I-3).
    await tester.enterText(portField, '47999');
    await tester.enterText(hostField, '192.168.1.99 ');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

    // Neither an address nor a host name: it can only fail later, at a point
    // where the error would blame the network (C-2).
    await tester.enterText(hostField, '999.999.999.999');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.enterText(hostField, '999.1.1.1/etc');
    await tester.pumpAndSettle();
    expect(find.textContaining('IP アドレス'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.enterText(hostField, '192.168.1.99');
    await tester.enterText(portField, '47999');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final saved = await SyncSettingsStore().load();
    expect(saved.host, '192.168.1.99');
    expect(saved.port, 47999);
    // Saving used to say nothing at all (C-2).
    expect(find.text('接続先を保存しました'), findsOneWidget);
  });

  testWidgets('接続先を手入力 opens empty on a phone that has never paired', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = await testContainer();
    await _pumpScreen(tester, container);

    await tester.tap(find.text('接続先を手入力'));
    await tester.pumpAndSettle();

    // Not `10.0.2.2`: that is the Android emulator's view of its host machine
    // and meant nothing to anyone holding a real phone (C-2 / I-8).
    final host = tester.widget<TextField>(find.byType(TextField).at(0));
    expect(host.controller!.text, isEmpty);
    expect(host.decoration!.hintText, '192.168.x.x');
    final port = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(port.controller!.text, '47820');
  });

  testWidgets('a host without a pairing says so and offers the way out', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SyncSettingsStore().save(const SyncSettings(host: '192.168.1.50'));
    final container = await testContainer();
    await _pumpScreen(tester, container);

    expect(find.text('未ペアリング'), findsOneWidget);
    expect(
      find.textContaining('接続先は設定済みですが、まだペアリングしていません。'),
      findsOneWidget,
    );
    expect(find.text('ペアリングへ進む'), findsOneWidget);
  });

  testWidgets('the sync screen names no hub tool outside the macOS guide', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = await testContainer();
    await _pumpScreen(tester, container);

    expect(find.textContaining('エミュレーター'), findsNothing);
    expect(find.text('QR が読めないとき（PC の IP を直接入力）'), findsOneWidget);
  });

  testWidgets('ファイルから取り込む reports a picker refusal without opening a panel', (tester) async {
    // Only the picker is exercised here: reading the chosen file is real
    // `dart:io`, which never completes inside the test binding's faked async,
    // so `readImportJson` itself is covered in `file_exporter_test.dart`.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final applied = _ApplyingSyncService();
    final container = await testContainer(
      overrides: <Override>[syncServiceProvider.overrideWithValue(applied)],
    );
    await _pumpScreen(tester, container);
    final tile = find.text('ファイルから取り込む');
    await tester.scrollUntilVisible(tile, 200);
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();

    // The picker's own Japanese FormatException — the file the user chose was
    // refused before anything was read, so this is a snackbar, not a sync.
    _usePicker(_ThrowingOpenFilePicker(const FormatException('この形式は選べません')));
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text('この形式は選べません'), findsOneWidget);
    expect(find.text('待機中'), findsNothing);
    expect(applied.received, 0);

    // Backing out of the chooser is not an error and opens no panel either.
    _usePicker(_FakeOpenFilePicker(null));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byType(SyncProgressPanel), findsNothing);
    expect(applied.received, 0);
  }, skip: !Platform.isMacOS);

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
