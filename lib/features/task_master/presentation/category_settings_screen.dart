import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/task_master_controller.dart';
import '../domain/task_models.dart';

class CategorySettingsScreen extends ConsumerWidget {
  const CategorySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(taskMasterControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('カテゴリ設定')),
      body: state.when(
        data: (data) => ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              child: SwitchListTile(
                title: const Text('カテゴリを共有する'),
                subtitle: const Text('やるべきこと / やりたいこと でカテゴリ体系を共通化します。'),
                value: data.shareCategories,
                onChanged: (enabled) async {
                  final controller = ref.read(
                    taskMasterControllerProvider.notifier,
                  );
                  if (!enabled) {
                    await controller.setShareCategories(enabled: false);
                    return;
                  }

                  final strategy = await showDialog<CategoryMergeStrategy>(
                    context: context,
                    builder: (context) => const _MergeStrategyDialog(),
                  );
                  if (strategy == null) {
                    return;
                  }
                  await controller.setShareCategories(
                    enabled: true,
                    strategy: strategy,
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            if (data.shareCategories)
              _CategorySection(
                title: '共通カテゴリ',
                kind: TaskKind.mustDo,
                categories: data.mustDoCategories,
              )
            else ...[
              _CategorySection(
                title: 'やるべきことカテゴリ',
                kind: TaskKind.mustDo,
                categories: data.mustDoCategories,
              ),
              const SizedBox(height: 16),
              _CategorySection(
                title: 'やりたいことカテゴリ',
                kind: TaskKind.wantToDo,
                categories: data.wantToDoCategories,
              ),
            ],
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(child: Text(error.toString())),
      ),
    );
  }
}

class _CategorySection extends ConsumerWidget {
  const _CategorySection({
    required this.title,
    required this.kind,
    required this.categories,
  });

  final String title;
  final TaskKind kind;
  final List<TaskCategory> categories;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _openCategoryDialog(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('追加'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...categories.map(
              (category) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(category.name),
                trailing: Wrap(
                  spacing: 8,
                  children: [
                    IconButton(
                      onPressed: () =>
                          _openCategoryDialog(context, ref, category: category),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      onPressed: () async {
                        await ref
                            .read(taskMasterControllerProvider.notifier)
                            .deleteCategory(
                              kind: kind,
                              categoryId: category.id,
                            );
                      },
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openCategoryDialog(
    BuildContext context,
    WidgetRef ref, {
    TaskCategory? category,
  }) async {
    final controller = TextEditingController(text: category?.name ?? '');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(category == null ? 'カテゴリ追加' : 'カテゴリ編集'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'カテゴリ名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) {
                return;
              }
              await ref
                  .read(taskMasterControllerProvider.notifier)
                  .upsertCategory(
                    kind: kind,
                    category: TaskCategory(
                      id:
                          category?.id ??
                          '${kind.storageKey}-${DateTime.now().microsecondsSinceEpoch}',
                      name: name,
                    ),
                  );
              if (context.mounted) {
                Navigator.of(context).pop();
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
  }
}

class _MergeStrategyDialog extends StatefulWidget {
  const _MergeStrategyDialog();

  @override
  State<_MergeStrategyDialog> createState() => _MergeStrategyDialogState();
}

class _MergeStrategyDialogState extends State<_MergeStrategyDialog> {
  CategoryMergeStrategy _value = CategoryMergeStrategy.keepLonger;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('共有化の基準を選択'),
      content: DropdownButtonFormField<CategoryMergeStrategy>(
        initialValue: _value,
        decoration: const InputDecoration(labelText: '統合ルール'),
        items: CategoryMergeStrategy.values
            .map(
              (strategy) => DropdownMenuItem<CategoryMergeStrategy>(
                value: strategy,
                child: Text(strategy.label),
              ),
            )
            .toList(),
        onChanged: (value) {
          if (value != null) {
            setState(() => _value = value);
          }
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_value),
          child: const Text('適用'),
        ),
      ],
    );
  }
}
