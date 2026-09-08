import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/app/theme.dart';
import 'package:frelocator/features/task_master/domain/task_models.dart';
import 'package:frelocator/features/task_master/presentation/category_settings_screen.dart';
import 'package:frelocator/services/storage/prefs_state_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_container.dart';

void main() {
  late ProviderContainer container;

  TaskMaster task(String id, String? categoryId) => TaskMaster(
    id: id,
    title: 'タスク $id',
    kind: TaskKind.mustDo,
    priority: 3,
    createdAt: DateTime(2026, 4, 18),
    updatedAt: DateTime(2026, 4, 18),
    categoryId: categoryId,
  );

  setUp(() async {
    final seeded = TaskMasterStateData(
      tasks: <TaskMaster>[
        task('t1', 'cat-work'),
        task('t2', 'cat-work'),
        task('t3', null),
      ],
      mustDoCategories: <TaskCategory>[TaskCategory(id: 'cat-work', name: '仕事')],
      wantToDoCategories: const <TaskCategory>[],
      shareCategories: false,
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.${PrefsStateStore.taskKey}': seeded.encode(),
    });
    container = await testContainer();
  });

  tearDown(() => container.dispose());

  Future<void> pump(WidgetTester tester, {double textScale = 1}) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: const CategorySettingsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the section title stays whole at a 1.6 text scale', (
    tester,
  ) async {
    await pump(tester, textScale: 1.6);
    final title = tester.renderObject<RenderParagraph>(
      find.text('やるべきことカテゴリ'),
    );
    expect(title.didExceedMaxLines, isFalse);
    // The heading, not the 追加 button, gets the width that is left over.
    expect(
      tester.getSize(find.text('やるべきことカテゴリ')).width,
      greaterThan(
        tester.getSize(find.widgetWithText(FilledButton, '追加').first).width,
      ),
    );
  });

  testWidgets('deleting a used category says how many tasks lose it', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byTooltip('カテゴリを削除').first);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('このカテゴリを使っている 2 件のタスクは未分類になります。'),
      findsOneWidget,
    );
  });
}
