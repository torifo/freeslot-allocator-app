import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/app/theme.dart';
import 'package:frelocator/features/task_master/presentation/task_master_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_container.dart';

void main() {
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    container = await testContainer();
  });

  tearDown(() => container.dispose());

  Future<void> pump(
    WidgetTester tester, {
    double width = 390,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: const TaskMasterScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder chipLabel(String label) => find.descendant(
    of: find.byType(ChoiceChip),
    matching: find.text(label),
  );

  testWidgets('the three filter chips share the row without spilling over', (
    tester,
  ) async {
    await pump(tester);

    final row = tester.getSize(find.byType(ChoiceChip).first);
    expect(row.width, greaterThan(0));
    for (final label in <String>['すべて', 'やるべきこと', 'やりたいこと']) {
      // Cut short if it has to be, never wrapped onto a second line: one tall
      // chip beside two short ones was the shape the row used to take (M-4).
      final text = tester.renderObject<RenderParagraph>(chipLabel(label));
      expect(text.maxLines, 1, reason: label);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow phone wraps the chips instead of squeezing them', (
    tester,
  ) async {
    await pump(tester, width: 320);

    expect(
      find.ancestor(of: chipLabel('やりたいこと'), matching: find.byType(Wrap)),
      findsWidgets,
    );
    final label = tester.renderObject<RenderParagraph>(chipLabel('やりたいこと'));
    expect(label.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull);
  });
}
