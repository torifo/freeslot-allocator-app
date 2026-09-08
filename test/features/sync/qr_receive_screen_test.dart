import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/sync/presentation/qr_receive_screen.dart';
import 'package:frelocator/features/sync/presentation/qr_scanner.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/features/sync/application/sync_in_flight.dart';
import 'package:frelocator/services/sync/lan_sync_types.dart';
import 'package:frelocator/services/sync/qr_chunk_codec.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:frelocator/services/sync/sync_progress.dart';
import 'package:frelocator/services/sync/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_container.dart';

/// A scanner the test drives by hand: it keeps the callback the screen gave it
/// so frames can be delivered without a camera or the `mobile_scanner` plugin.
class _FakeScanner extends QrScanner {
  _FakeScanner({this.error});

  /// When set, the seam renders the screen's `errorBuilder` instead of a
  /// preview — what `mobile_scanner` does when the camera refuses to open.
  /// Cleared by a test that wants the next attempt to succeed, the way granting
  /// the permission in the settings app does.
  QrScannerError? error;

  /// How many times the screen has asked for a preview.
  int builds = 0;

  QrCodesCallback? onCodes;
  QrScanSpeed? speed;

  @override
  bool get isAvailable => true;

  @override
  Widget build({
    required QrCodesCallback onCodes,
    QrScanSpeed speed = QrScanSpeed.normal,
    QrErrorBuilder? errorBuilder,
  }) {
    this.onCodes = onCodes;
    this.speed = speed;
    builds += 1;
    final failure = error;
    if (failure != null && errorBuilder != null) {
      return Builder(builder: (ctx) => errorBuilder(ctx, failure));
    }
    return const SizedBox(key: Key('fake-scanner'));
  }
}

Map<String, dynamic> _document({String deviceId = 'hub-macos'}) => SyncDocument(
  exportedAt: DateTime.utc(2026, 9, 9, 1, 2, 3),
  deviceId: deviceId,
  taskMaster: TaskMasterStateData.initial(),
  dailyPlan: DailyPlanStateData.initial(),
).toJson();

/// Fails every merge, so the screen has to survive `applyReceived` saying no.
class _FailingSyncService implements SyncService {
  int calls = 0;

  @override
  Future<SyncOutcome> applyReceived(
    Map<String, dynamic> json, {
    SyncMode mode = SyncMode.merge,
    SyncProgressController? progress,
  }) async {
    calls += 1;
    progress?.fail('invalid_document', syncErrorMessage('invalid_document'));
    return SyncFailed('invalid_document', syncErrorMessage('invalid_document'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

void main() {
  late _FakeScanner scanner;
  late ProviderContainer container;

  Future<void> pump(
    WidgetTester tester, {
    _FakeScanner? withScanner,
    List<Override> overrides = const <Override>[],
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    scanner = withScanner ?? _FakeScanner();
    container = await testContainer(
      overrides: <Override>[
        qrScannerProvider.overrideWithValue(scanner),
        ...overrides,
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: QrReceiveScreen()),
      ),
    );
    // Not `pumpAndSettle`: the panel is scanning, so its bar keeps animating.
    await tester.pump();
  }

  Future<void> feed(WidgetTester tester, List<String> codes) async {
    scanner.onCodes!(codes);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('counts frames as they arrive and lists what is missing', (tester) async {
    final frames = encodeQrFrames(_document(), chunkChars: 120);
    expect(frames.length, greaterThan(2));
    await pump(tester);

    await feed(tester, <String>[frames[0]]);
    expect(find.text('読み取り中'), findsOneWidget);
    expect(find.text('1 / ${frames.length} コマ受信'), findsOneWidget);
    expect(
      find.text('未受信: ${[for (var i = 2; i <= frames.length; i += 1) i].join(', ')}'),
      findsOneWidget,
    );

    // The same frame twice is what a camera does; it must not be counted again.
    await feed(tester, <String>[frames[0]]);
    expect(find.text('1 / ${frames.length} コマ受信'), findsOneWidget);
  });

  testWidgets('a complete set is decoded and merged', (tester) async {
    final frames = encodeQrFrames(_document(), chunkChars: 200);
    await pump(tester);

    // In reverse: the order the camera happens to catch them in is irrelevant.
    for (final frame in frames.reversed) {
      await feed(tester, <String>[frame]);
    }
    await tester.pumpAndSettle();

    expect(find.text('完了'), findsOneWidget);
    expect(find.textContaining('追加 '), findsOneWidget);
    // The camera preview is gone once there is nothing left to scan.
    expect(find.byKey(const Key('fake-scanner')), findsNothing);
  });

  testWidgets('a frame from another payload asks before throwing work away', (tester) async {
    final mine = encodeQrFrames(_document(), chunkChars: 120);
    final other = encodeQrFrames(_document(deviceId: 'other-phone'), chunkChars: 120);
    await pump(tester);

    await feed(tester, <String>[mine[0]]);
    expect(find.text('1 / ${mine.length} コマ受信'), findsOneWidget);

    await feed(tester, <String>[other[0]]);
    expect(find.text('別のデータです'), findsOneWidget);

    await tester.tap(find.text('いいえ'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // Refusing keeps the frames already scanned, and the foreign one is dropped.
    expect(find.text('1 / ${mine.length} コマ受信'), findsOneWidget);

    await feed(tester, <String>[other[0]]);
    expect(find.text('別のデータです'), findsOneWidget);
    await tester.tap(find.text('やり直す'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('1 / ${other.length} コマ受信'), findsOneWidget);
  });

  testWidgets('a misread frame is dropped with a note instead of poisoning the set', (tester) async {
    final frames = encodeQrFrames(_document(), chunkChars: 120);
    await pump(tester);

    final broken = '${frames[0].substring(0, frames[0].length - 1)}'
        '${frames[0].endsWith('A') ? 'B' : 'A'}';
    await feed(tester, <String>[broken]);

    expect(find.textContaining('読み取りエラーのコマを捨てました'), findsOneWidget);

    // A frame that reads cleanly means the camera is working again, so the
    // warning must not linger under a counter that is moving.
    await feed(tester, <String>[frames[0]]);
    expect(find.textContaining('読み取りエラーのコマを捨てました'), findsNothing);
  });

  testWidgets('the QR screen asks the camera for every frame it can give', (tester) async {
    await pump(tester);
    // The hub flips frames every 200–1000 ms; the plugin's default 250 ms
    // throttle beats against that and drops whole frames.
    expect(scanner.speed, QrScanSpeed.unrestricted);
  });

  testWidgets('a refused camera explains itself and points at the other routes', (tester) async {
    await pump(tester, withScanner: _FakeScanner(error: QrScannerError.permissionDenied));

    // Twice over: once where the preview would be, once in the progress panel
    // — the explanation stays next to the retry button (I-2).
    expect(find.textContaining('カメラの使用が許可されていません'), findsWidgets);
    // The other route is named for the platform the test runs on (macOS here).
    expect(find.textContaining('ファイルから取り込む'), findsWidgets);
    expect(find.byKey(const Key('fake-scanner')), findsNothing);
  });

  testWidgets('a camera that cannot start is a failure, not a slow scan', (tester) async {
    await pump(tester, withScanner: _FakeScanner(error: QrScannerError.permissionDenied));

    // The panel used to keep ticking under the error and eventually claim the
    // transfer was 「時間がかかっています」 (I-9).
    expect(find.text('失敗'), findsOneWidget);
    await tester.pump(const Duration(seconds: 20));
    expect(find.textContaining('時間がかかっています'), findsNothing);
  });

  testWidgets('any other camera failure gets the generic Japanese line', (tester) async {
    await pump(tester, withScanner: _FakeScanner(error: QrScannerError.other));
    expect(find.textContaining(syncErrorMessage('camera')), findsWidgets);
  });

  testWidgets('a failed camera can be tried again from the screen', (
    tester,
  ) async {
    final failing = _FakeScanner(error: QrScannerError.permissionDenied);
    await pump(tester, withScanner: failing);

    expect(find.text('失敗'), findsOneWidget);
    expect(find.byKey(const Key('fake-scanner')), findsNothing);
    final buildsBeforeRetry = failing.builds;

    // The user grants the permission and comes back.
    failing.error = null;
    await tester.tap(find.text('もう一度試す'));
    await tester.pump();

    expect(failing.builds, greaterThan(buildsBeforeRetry));
    expect(find.byKey(const Key('fake-scanner')), findsOneWidget);
    // The panel is scanning again rather than still saying 失敗.
    expect(find.text('失敗'), findsNothing);
    expect(find.text('読み取り中'), findsOneWidget);
    expect(find.text('もう一度試す'), findsNothing);
  });

  testWidgets('coming back to the app retries the camera by itself', (
    tester,
  ) async {
    final failing = _FakeScanner(error: QrScannerError.permissionDenied);
    await pump(tester, withScanner: failing);
    expect(find.text('失敗'), findsOneWidget);

    // Granting the permission happens in the settings app; the way back is a
    // resume, not a tap on this screen.
    failing.error = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(find.byKey(const Key('fake-scanner')), findsOneWidget);
    expect(find.text('読み取り中'), findsOneWidget);
  });

  testWidgets('the instructions name no hub tool', (tester) async {
    await pump(tester);
    // `sync_status` / `lan.qrPage` belong to the macOS guide, not here (C-1).
    expect(find.textContaining('sync_status'), findsNothing);
    expect(find.textContaining('lan.qrPage'), findsNothing);
    expect(find.textContaining('PC 側で QR 画面を開き'), findsOneWidget);
  });

  testWidgets('a merge that fails leaves the screen scannable again', (tester) async {
    final service = _FailingSyncService();
    final frames = encodeQrFrames(_document(), chunkChars: 200);
    await pump(
      tester,
      overrides: <Override>[syncServiceProvider.overrideWithValue(service)],
    );

    for (final frame in frames) {
      await feed(tester, <String>[frame]);
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(service.calls, 1);
    expect(find.text('失敗'), findsOneWidget);
    expect(find.text(syncErrorMessage('invalid_document')), findsOneWidget);
    // The flag the app's foreground reload waits on comes back down even
    // though the merge answered with a failure.
    expect(container.read(syncInFlightProvider), isFalse);
    // The camera is back, and scanning again restarts rather than replaying
    // the failure.
    expect(find.byKey(const Key('fake-scanner')), findsOneWidget);
    await feed(tester, <String>[frames[0]]);
    expect(find.text('読み取り中'), findsOneWidget);
    expect(find.text('1 / ${frames.length} コマ受信'), findsOneWidget);
    expect(service.calls, 1);
  });
}
