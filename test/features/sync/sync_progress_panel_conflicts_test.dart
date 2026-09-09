import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/sync/presentation/sync_progress_panel.dart';
import 'package:frelocator/services/sync/sync_progress.dart';

Future<SyncProgressController> _pumpPanel(
  WidgetTester tester, {
  VoidCallback? onOpenConflicts,
}) async {
  final controller = SyncProgressController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SyncProgressPanel(
          controller: controller,
          onCancel: () {},
          onClose: () {},
          onOpenConflicts: onOpenConflicts,
        ),
      ),
    ),
  );
  return controller;
}

void main() {
  testWidgets('the completion line adds 競合 n and a way in', (tester) async {
    var opened = 0;
    final controller = await _pumpPanel(tester, onOpenConflicts: () => opened += 1);
    controller.start(SyncKind.lan);
    controller.finish(
      const SyncSummary(added: 1, updated: 0, deleted: 0, warnings: 0, conflicts: 2),
    );
    await tester.pumpAndSettle();

    // The sync itself succeeded: the conflict count is a note, not a failure.
    expect(find.text('完了'), findsOneWidget);
    expect(find.text('失敗'), findsNothing);
    expect(find.textContaining('競合 2'), findsOneWidget);

    await tester.tap(find.text('確認する'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('a clean sync offers no way in', (tester) async {
    final controller = await _pumpPanel(tester, onOpenConflicts: () {});
    controller.start(SyncKind.lan);
    controller.finish(const SyncSummary(added: 1, updated: 0, deleted: 0, warnings: 0));
    await tester.pumpAndSettle();

    expect(find.textContaining('競合 0'), findsOneWidget);
    expect(find.text('確認する'), findsNothing);
  });
}
