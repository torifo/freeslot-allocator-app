import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/daily_plan/domain/daily_plan_models.dart';
import 'package:frelocator/features/sync/presentation/qr_receive_screen.dart';
import 'package:frelocator/features/sync/presentation/qr_scanner.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/services/sync/qr_chunk_codec.dart';
import 'package:frelocator/services/sync/sync_document.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_container.dart';

/// A scanner the test drives by hand: it keeps the callback the screen gave it
/// so frames can be delivered without a camera or the `mobile_scanner` plugin.
class _FakeScanner extends QrScanner {
  _FakeScanner();

  QrCodesCallback? onCodes;

  @override
  bool get isAvailable => true;

  @override
  Widget build({required QrCodesCallback onCodes}) {
    this.onCodes = onCodes;
    return const SizedBox(key: Key('fake-scanner'));
  }
}

Map<String, dynamic> _document({String deviceId = 'hub-macos'}) => SyncDocument(
  exportedAt: DateTime.utc(2026, 9, 9, 1, 2, 3),
  deviceId: deviceId,
  taskMaster: TaskMasterStateData.initial(),
  dailyPlan: DailyPlanStateData.initial(),
).toJson();

void main() {
  late _FakeScanner scanner;

  Future<void> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    scanner = _FakeScanner();
    final container = await testContainer(
      overrides: <Override>[qrScannerProvider.overrideWithValue(scanner)],
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
  });
}
