import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/sync/presentation/sync_progress_panel.dart';
import 'package:frelocator/services/sync/sync_progress.dart';

Future<SyncProgressController> _pumpPanel(
  WidgetTester tester, {
  VoidCallback? onCancel,
  VoidCallback? onClose,
}) async {
  final controller = SyncProgressController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SyncProgressPanel(
          controller: controller,
          onCancel: onCancel ?? () {},
          onClose: onClose ?? () {},
        ),
      ),
    ),
  );
  return controller;
}

void main() {
  testWidgets('every stage has a Japanese label', (tester) async {
    final controller = await _pumpPanel(tester);
    controller.start(SyncKind.lan);
    await tester.pump();
    expect(find.text('接続中'), findsOneWidget);

    for (final (stage, label) in const <(SyncStage, String)>[
      (SyncStage.sending, '送信中'),
      (SyncStage.waitingHub, 'PC で処理中'),
      (SyncStage.receiving, '受信中'),
      (SyncStage.applying, 'マージ中'),
      (SyncStage.saving, '保存中'),
    ]) {
      controller.stage(stage);
      await tester.pump();
      expect(find.text(label), findsOneWidget, reason: '$stage');
    }
  });

  testWidgets('sending shows the bytes, waitingHub says it cannot be measured', (tester) async {
    final controller = await _pumpPanel(tester);
    controller.start(SyncKind.lan);
    controller.stage(SyncStage.sending, totalBytes: 2048);
    controller.bytes(1024);
    await tester.pump();
    expect(find.text('1.0 KB / 2.0 KB'), findsOneWidget);

    controller.stage(SyncStage.waitingHub);
    await tester.pump();
    expect(find.text('PC がマージしています（進捗は計測できません）'), findsOneWidget);
  });

  testWidgets('the done summary counts 消去 apart from 削除', (tester) async {
    final controller = await _pumpPanel(tester);
    controller.start(SyncKind.lan);
    controller.finish(
      const SyncSummary(added: 2, updated: 3, deleted: 4, warnings: 1, removed: 5),
    );
    await tester.pumpAndSettle();

    expect(find.text('完了'), findsOneWidget);
    expect(find.text('追加 2 / 更新 3 / 削除 4 / 消去 5 / 警告 1 / 競合 0'), findsOneWidget);
    // Nothing left to wait for, so the panel offers a way out and no cancel.
    expect(find.text('閉じる'), findsOneWidget);
    expect(find.text('キャンセル'), findsNothing);
  });

  testWidgets('a failure shows the Japanese message it was given', (tester) async {
    final controller = await _pumpPanel(tester);
    controller.start(SyncKind.lan);
    controller.fail('unreachable', 'PC に接続できません。');
    await tester.pumpAndSettle();

    expect(find.text('失敗'), findsOneWidget);
    expect(find.text('PC に接続できません。'), findsOneWidget);
  });

  testWidgets('cancelling after the hand-off warns that the PC may have changed', (tester) async {
    var cancels = 0;
    final controller = await _pumpPanel(tester, onCancel: () => cancels += 1);
    controller.start(SyncKind.lan);
    controller.stage(SyncStage.waitingHub);
    await tester.pump();

    await tester.tap(find.text('キャンセル'));
    expect(cancels, 1);
    controller.cancel();
    await tester.pumpAndSettle();

    expect(find.text('中止しました'), findsOneWidget);
    expect(
      find.text('PC は更新済みの可能性があります。この端末への反映だけ中止しました。'),
      findsOneWidget,
    );
  });

  testWidgets('saving cannot be cancelled halfway through the write', (tester) async {
    final controller = await _pumpPanel(tester);
    controller.start(SyncKind.lan);
    controller.stage(SyncStage.saving);
    await tester.pump();

    expect(find.text('保存中'), findsOneWidget);
    expect(find.text('キャンセル'), findsNothing);
  });

  testWidgets('a QR transfer shows the frame grid and what is still missing', (tester) async {
    final controller = await _pumpPanel(tester);
    controller.start(SyncKind.qr);
    controller.stage(SyncStage.scanning);
    controller.frames(received: 2, total: 4, missing: <int>[1, 3]);
    await tester.pump();

    expect(find.text('2 / 4 コマ受信'), findsOneWidget);
    expect(find.text('未受信: 2, 4'), findsOneWidget);
    // One square per frame, numbered from 1.
    for (final label in <String>['1', '2', '3', '4']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('a QR transfer with hundreds of frames neither overflows nor lists them all', (tester) async {
    final controller = await _pumpPanel(tester);
    controller.start(SyncKind.qr);
    controller.stage(SyncStage.scanning);
    controller.frames(
      received: 1,
      total: 300,
      missing: <int>[for (var i = 1; i < 300; i += 1) i],
    );
    await tester.pump();

    // The panel scrolls its own body, so 300 squares cannot run off the sheet.
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);

    // 12 numbers and a count, not 299 numbers.
    expect(
      find.text('未受信: 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 他 287 コマ'),
      findsOneWidget,
    );
  });

  testWidgets('a short 未受信 list is spelled out in full', (tester) async {
    final controller = await _pumpPanel(tester);
    controller.start(SyncKind.qr);
    controller.stage(SyncStage.scanning);
    controller.frames(received: 2, total: 4, missing: <int>[2, 3]);
    await tester.pump();
    expect(find.text('未受信: 3, 4'), findsOneWidget);
  });

  testWidgets('the embedded panel leaves the scrolling to its host', (tester) async {
    final controller = SyncProgressController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: <Widget>[
              SyncProgressPanel(
                controller: controller,
                onCancel: () {},
                onClose: () {},
                scrollable: false,
              ),
            ],
          ),
        ),
      ),
    );
    controller.start(SyncKind.qr);
    await tester.pump();
    // Only the host's list: a scrollable inside a scrollable would fight the
    // user's finger for the gesture.
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
