import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/sync/presentation/sync_replace_dialog.dart';
import 'package:frelocator/services/sync/lan_sync_types.dart';
import 'package:frelocator/services/sync/sync_service.dart';

Future<SyncMode?> _open(WidgetTester tester, String tap) async {
  SyncMode? choice;
  var opened = false;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              opened = true;
              choice = await SyncReplaceDialog.show(
                context,
                syncErrorMessage('purged_before'),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(opened, isTrue);
  await tester.tap(find.text(tap));
  await tester.pumpAndSettle();
  return choice;
}

void main() {
  testWidgets('shows the destructive warning and the backup note', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SyncReplaceDialog(message: syncErrorMessage('purged_before')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('どちらを正にしますか？'), findsOneWidget);
    expect(find.textContaining('この端末の未同期の変更は消えます'), findsOneWidget);
    expect(find.textContaining('PC 側の変更'), findsOneWidget);
    expect(find.textContaining('「直前の同期前に戻す」で 1 回だけ元に戻せます'), findsOneWidget);
  });

  testWidgets('キャンセル returns nothing', (tester) async {
    expect(await _open(tester, 'キャンセル'), isNull);
  });

  testWidgets('PC の状態で置き換える returns take_hub', (tester) async {
    expect(await _open(tester, 'PC の状態で置き換える'), SyncMode.takeHub);
  });

  testWidgets('この端末で PC を置き換える returns take_phone', (tester) async {
    expect(await _open(tester, 'この端末で PC を置き換える'), SyncMode.takePhone);
  });
}
