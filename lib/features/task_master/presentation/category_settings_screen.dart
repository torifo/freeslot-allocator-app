import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/confirm_dialog.dart';
import '../../../core/error_view.dart';
import '../../../core/id_generator.dart';
import '../application/task_master_controller.dart';
import '../application/task_master_logic.dart';
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
                tasks: data.tasks,
              )
            else ...[
              _CategorySection(
                title: 'やるべきことカテゴリ',
                kind: TaskKind.mustDo,
                categories: data.mustDoCategories,
                tasks: data.tasks,
              ),
              const SizedBox(height: 16),
              _CategorySection(
                title: 'やりたいことカテゴリ',
                kind: TaskKind.wantToDo,
                categories: data.wantToDoCategories,
                tasks: data.tasks,
              ),
            ],
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.devices),
                title: const Text('PC と同期'),
                // 「…ファイルでデータを…」 broke between デ and ー at large text
                // scales; the shorter line has no such seam (M-8).
                subtitle: const Text('同じ Wi-Fi の PC・QR・ファイル経由でやり取りします'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/sync'),
              ),
            ),
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => ErrorView(
          onRetry: () => ref.invalidate(taskMasterControllerProvider),
        ),
      ),
    );
  }
}

class _CategorySection extends ConsumerWidget {
  const _CategorySection({
    required this.title,
    required this.kind,
    required this.categories,
    required this.tasks,
  });

  final String title;
  final TaskKind kind;
  final List<TaskCategory> categories;

  /// Every task, so a delete can say how many of them lose their category.
  final List<TaskMaster> tasks;

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
                const SizedBox(width: 12),
                // Not `Flexible`: sharing the row evenly let the button claim
                // half the width and squeezed 「やるべきことカテゴリ」 into an
                // ellipsis at large text scales. The button takes what it
                // needs, the title keeps the rest (I-5).
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
                      tooltip: 'カテゴリを編集',
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        // Deleting a category quietly un-files whatever used
                        // it; say how much before asking (I-4).
                        final usedBy = tasks
                            .where((task) => task.categoryId == category.id)
                            .length;
                        final confirmed = await confirmDelete(
                          context,
                          name: category.name,
                          description: usedBy > 0
                              ? 'このカテゴリを使っている $usedBy 件のタスクは未分類になります。'
                              : null,
                        );
                        if (!confirmed) {
                          return;
                        }
                        await ref
                            .read(taskMasterControllerProvider.notifier)
                            .deleteCategory(
                              kind: kind,
                              categoryId: category.id,
                            );
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text('「${category.name}」を削除しました'),
                          ),
                        );
                      },
                      tooltip: 'カテゴリを削除',
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
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _CategoryEditDialog(
        kind: kind,
        category: category,
        onSave: (saved) async {
          await ref
              .read(taskMasterControllerProvider.notifier)
              .upsertCategory(kind: kind, category: saved);
          if (!context.mounted) {
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(category == null ? 'カテゴリを追加しました' : 'カテゴリを保存しました'),
            ),
          );
        },
      ),
    );
  }
}

class _CategoryEditDialog extends StatefulWidget {
  const _CategoryEditDialog({
    required this.kind,
    required this.onSave,
    this.category,
  });

  final TaskKind kind;
  final TaskCategory? category;
  final Future<void> Function(TaskCategory category) onSave;

  @override
  State<_CategoryEditDialog> createState() => _CategoryEditDialogState();
}

class _CategoryEditDialogState extends State<_CategoryEditDialog> {
  late final TextEditingController _controller;
  String? _errorText;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.category?.name ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _errorText = 'カテゴリ名を入力してください');
      return;
    }

    setState(() {
      _errorText = null;
      _isSaving = true;
    });
    try {
      await widget.onSave(
        TaskCategory(
          id: widget.category?.id ?? generateId(widget.kind.storageKey),
          name: name,
        ),
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on TaskMasterValidationException catch (error) {
      if (mounted) {
        setState(() => _errorText = error.message);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text(saveFailureMessage)));
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(widget.category == null ? 'カテゴリ追加' : 'カテゴリ編集'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        enabled: !_isSaving,
        onSubmitted: (_) => _isSaving ? null : _submit(),
        decoration: InputDecoration(
          labelText: 'カテゴリ名',
          errorText: _errorText,
          // 「同じ名前のカテゴリがすでにあります」 needs two lines at a large
          // text scale; on one it was cut off mid-word (I-6).
          errorMaxLines: 2,
          helperMaxLines: 2,
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _submit,
          child: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
      ],
    );
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
      scrollable: true,
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
