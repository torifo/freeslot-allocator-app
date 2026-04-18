import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../application/task_master_controller.dart';
import '../application/task_master_logic.dart';
import '../domain/task_models.dart';

class TaskMasterScreen extends ConsumerStatefulWidget {
  const TaskMasterScreen({super.key});

  @override
  ConsumerState<TaskMasterScreen> createState() => _TaskMasterScreenState();
}

class _TaskMasterScreenState extends ConsumerState<TaskMasterScreen> {
  TaskKind? _filter;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(taskMasterControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('TaskMaster'),
        actions: [
          IconButton(
            onPressed: () => context.go('/categories'),
            icon: const Icon(Icons.tune),
            tooltip: 'カテゴリ設定',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openTaskDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('追加'),
      ),
      body: state.when(
        data: (data) {
          final visibleTasks = _filter == null
              ? data.tasks
              : data.tasks.where((task) => task.kind == _filter).toList();

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('すべて'),
                    selected: _filter == null,
                    onSelected: (_) => setState(() => _filter = null),
                  ),
                  ...TaskKind.values.map(
                    (kind) => ChoiceChip(
                      label: Text(kind.label),
                      selected: _filter == kind,
                      onSelected: (_) => setState(() => _filter = kind),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ...visibleTasks.map(
                (task) => Card(
                  child: ListTile(
                    title: Text(task.title),
                    subtitle: Text(
                      [
                        task.kind.label,
                        _categoryName(data, task) ?? '未分類',
                        '優先度 ${task.priority}',
                        if (task.estimatedMinutes > 0)
                          '${task.estimatedMinutes}分',
                        DateFormat('yyyy/MM/dd HH:mm').format(task.updatedAt),
                      ].join(' / '),
                    ),
                    isThreeLine: task.memo.isNotEmpty,
                    trailing: PopupMenuButton<String>(
                      onSelected: (value) async {
                        if (value == 'edit') {
                          await _openTaskDialog(context, existing: task);
                        } else if (value == 'delete') {
                          await ref
                              .read(taskMasterControllerProvider.notifier)
                              .deleteTask(task.id);
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'edit', child: Text('編集')),
                        PopupMenuItem(value: 'delete', child: Text('削除')),
                      ],
                    ),
                  ),
                ),
              ),
              if (visibleTasks.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('タスクはまだありません。画面右下の追加ボタンから登録してください。'),
                  ),
                ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(child: Text(error.toString())),
      ),
    );
  }

  String? _categoryName(TaskMasterStateData data, TaskMaster task) {
    if (task.categoryId == null) {
      return null;
    }
    return data
        .categoriesFor(task.kind)
        .where((category) => category.id == task.categoryId)
        .firstOrNull
        ?.name;
  }

  Future<void> _openTaskDialog(
    BuildContext context, {
    TaskMaster? existing,
  }) async {
    final state = ref.read(taskMasterControllerProvider).requireValue;
    await showDialog<void>(
      context: context,
      builder: (context) => _TaskEditDialog(
        initialTask: existing,
        state: state,
        onSave: (task) async {
          try {
            await ref
                .read(taskMasterControllerProvider.notifier)
                .addOrUpdateTask(task);
          } on TaskMasterValidationException catch (error) {
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(error.message)));
            }
            rethrow;
          }
        },
      ),
    );
  }
}

class _TaskEditDialog extends StatefulWidget {
  const _TaskEditDialog({
    required this.state,
    required this.onSave,
    this.initialTask,
  });

  final TaskMasterStateData state;
  final TaskMaster? initialTask;
  final Future<void> Function(TaskMaster task) onSave;

  @override
  State<_TaskEditDialog> createState() => _TaskEditDialogState();
}

class _TaskEditDialogState extends State<_TaskEditDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _memoController;
  late final TextEditingController _estimatedController;
  late TaskKind _kind;
  late int _priority;
  String? _categoryId;

  @override
  void initState() {
    super.initState();
    final task = widget.initialTask;
    _titleController = TextEditingController(text: task?.title ?? '');
    _memoController = TextEditingController(text: task?.memo ?? '');
    _estimatedController = TextEditingController(
      text: task?.estimatedMinutes.toString() ?? '',
    );
    _kind = task?.kind ?? TaskKind.mustDo;
    _priority = task?.priority ?? 3;
    _categoryId = task?.categoryId;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _memoController.dispose();
    _estimatedController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categories = widget.state.categoriesFor(_kind);

    return AlertDialog(
      title: Text(widget.initialTask == null ? 'タスク追加' : 'タスク編集'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(labelText: 'タイトル'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<TaskKind>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: '区分'),
              items: TaskKind.values
                  .map(
                    (kind) => DropdownMenuItem<TaskKind>(
                      value: kind,
                      child: Text(kind.label),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setState(() {
                  _kind = value;
                  final allowedIds = widget.state
                      .categoriesFor(_kind)
                      .map((category) => category.id)
                      .toSet();
                  if (_categoryId != null &&
                      !allowedIds.contains(_categoryId)) {
                    _categoryId = null;
                  }
                });
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _categoryId,
              decoration: const InputDecoration(labelText: 'カテゴリ'),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('未分類'),
                ),
                ...categories.map(
                  (category) => DropdownMenuItem<String?>(
                    value: category.id,
                    child: Text(category.name),
                  ),
                ),
              ],
              onChanged: (value) => setState(() => _categoryId = value),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _priority,
              decoration: const InputDecoration(labelText: '優先度'),
              items: List<int>.generate(5, (index) => index + 1)
                  .map(
                    (priority) => DropdownMenuItem<int>(
                      value: priority,
                      child: Text('$priority'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _priority = value);
                }
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _estimatedController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '見積もり時間（分）'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _memoController,
              minLines: 3,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'メモ'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () async {
            final title = _titleController.text.trim();
            if (title.isEmpty) {
              return;
            }
            final now = DateTime.now();
            try {
              await widget.onSave(
                TaskMaster(
                  id:
                      widget.initialTask?.id ??
                      now.microsecondsSinceEpoch.toString(),
                  title: title,
                  kind: _kind,
                  priority: _priority,
                  createdAt: widget.initialTask?.createdAt ?? now,
                  updatedAt: now,
                  memo: _memoController.text.trim(),
                  categoryId: _categoryId,
                  estimatedMinutes:
                      int.tryParse(_estimatedController.text.trim()) ?? 0,
                ),
              );
              if (context.mounted) {
                Navigator.of(context).pop();
              }
            } on TaskMasterValidationException {
              // Keep the dialog open so the user can correct the input.
            }
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
