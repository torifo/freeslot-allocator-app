import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/confirm_dialog.dart';
import '../../../core/error_view.dart';
import '../../../core/id_generator.dart';
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
          final sections = _filter == null
              ? <TaskKind>[TaskKind.mustDo, TaskKind.wantToDo]
              : <TaskKind>[_filter!];

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final isCompact = constraints.maxWidth < 420;
                  final chipWidth = isCompact
                      ? (constraints.maxWidth - 8) / 2
                      : null;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildFilterChip(
                        label: 'すべて',
                        selected: _filter == null,
                        width: chipWidth,
                        onSelected: (_) => setState(() => _filter = null),
                      ),
                      ...TaskKind.values.map(
                        (kind) => _buildFilterChip(
                          label: kind.label,
                          selected: _filter == kind,
                          width: chipWidth,
                          onSelected: (_) => setState(() => _filter = kind),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              ...sections.map((kind) {
                final sectionTasks = visibleTasks
                    .where((task) => task.kind == kind)
                    .toList();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _TaskSectionCard(
                    title: kind.label,
                    tasks: sectionTasks,
                    categoryNameForTask: (task) => _categoryName(data, task),
                    onEdit: (task) => _openTaskDialog(context, existing: task),
                    onDelete: (task) => _confirmDeleteTask(context, task),
                    onReorder: (orderedIds) => ref
                        .read(taskMasterControllerProvider.notifier)
                        .reorderTasks(kind: kind, orderedIds: orderedIds),
                  ),
                );
              }),
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
        error: (error, stackTrace) => ErrorView(
          onRetry: () => ref.invalidate(taskMasterControllerProvider),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteTask(BuildContext context, TaskMaster task) async {
    final confirmed = await confirmDelete(context, name: task.title);
    if (!confirmed) {
      return;
    }
    await ref.read(taskMasterControllerProvider.notifier).deleteTask(task.id);
  }

  Widget _buildFilterChip({
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
    double? width,
  }) {
    final chip = ChoiceChip(
      label: SizedBox(
        width: width,
        child: Text(label, textAlign: TextAlign.center),
      ),
      selected: selected,
      onSelected: onSelected,
    );
    return width == null ? chip : SizedBox(width: width, child: chip);
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
    final state = ref
        .read(taskMasterControllerProvider)
        .maybeWhen(data: (value) => value, orElse: () => null);
    if (state == null) {
      return;
    }
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
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text(saveFailureMessage)));
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
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _memoController;
  late final TextEditingController _estimatedController;
  late final TextEditingController _priorityController;
  late TaskKind _kind;
  String? _categoryId;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final task = widget.initialTask;
    _titleController = TextEditingController(text: task?.title ?? '');
    _memoController = TextEditingController(text: task?.memo ?? '');
    _estimatedController = TextEditingController(
      text: task?.estimatedMinutes.toString() ?? '',
    );
    _priorityController = TextEditingController(
      text: (task?.priority ?? 3).toString(),
    );
    _kind = task?.kind ?? TaskKind.mustDo;
    _categoryId = task?.categoryId;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _memoController.dispose();
    _estimatedController.dispose();
    _priorityController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final title = _titleController.text.trim();
    final priority = int.tryParse(_priorityController.text.trim()) ?? 3;
    final now = DateTime.now();
    setState(() => _isSaving = true);
    try {
      await widget.onSave(
        TaskMaster(
          id: widget.initialTask?.id ?? generateId('task'),
          title: title,
          kind: _kind,
          priority: priority < 1 ? 1 : priority,
          createdAt: widget.initialTask?.createdAt ?? now,
          updatedAt: now,
          memo: _memoController.text.trim(),
          categoryId: _categoryId,
          estimatedMinutes: int.tryParse(_estimatedController.text.trim()) ?? 0,
        ),
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (_) {
      // Keep the dialog open so the user can correct the input. The message
      // was already surfaced by the caller.
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = widget.state.categoriesFor(_kind);

    return AlertDialog(
      scrollable: true,
      title: Text(widget.initialTask == null ? 'タスク追加' : 'タスク編集'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _titleController,
                autofocus: true,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'タイトル'),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'タイトルを入力してください。';
                  }
                  return null;
                },
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
              TextFormField(
                controller: _priorityController,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '優先度',
                  helperText: '上に並ぶほど優先度が高くなります。あとでドラッグでも調整できます。',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _estimatedController,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: '見積もり時間（分）'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _memoController,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                minLines: 3,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'メモ'),
              ),
            ],
          ),
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

class _TaskSectionCard extends StatelessWidget {
  const _TaskSectionCard({
    required this.title,
    required this.tasks,
    required this.categoryNameForTask,
    required this.onEdit,
    required this.onDelete,
    required this.onReorder,
  });

  final String title;
  final List<TaskMaster> tasks;
  final String? Function(TaskMaster task) categoryNameForTask;
  final Future<void> Function(TaskMaster task) onEdit;
  final Future<void> Function(TaskMaster task) onDelete;
  final Future<void> Function(List<String> orderedIds) onReorder;

  @override
  Widget build(BuildContext context) {
    final isDesktopLike = switch (defaultTargetPlatform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => true,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => false,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('上にあるタスクほど優先度が高くなります。ドラッグで並び替えできます。'),
            const SizedBox(height: 12),
            if (tasks.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('まだタスクがありません。'),
              )
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: tasks.length,
                // onReorderItem already reports newIndex relative to the list
                // with the dragged item removed, so no manual adjustment.
                onReorderItem: (oldIndex, newIndex) async {
                  final reordered = List<TaskMaster>.from(tasks);
                  final moved = reordered.removeAt(oldIndex);
                  reordered.insert(newIndex, moved);
                  await onReorder(reordered.map((task) => task.id).toList());
                },
                itemBuilder: (context, index) {
                  final task = tasks[index];
                  final dragIcon = Tooltip(
                    message: isDesktopLike ? 'ドラッグして並び替え' : '長押しして並び替え',
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.drag_handle),
                    ),
                  );
                  return Card(
                    key: ValueKey(task.id),
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      contentPadding: const EdgeInsets.only(left: 12, right: 4),
                      title: Text(task.title),
                      subtitle: Text(
                        [
                          categoryNameForTask(task) ?? '未分類',
                          '優先度 ${task.priority}',
                          if (task.estimatedMinutes > 0)
                            '${task.estimatedMinutes}分',
                          DateFormat('yyyy/MM/dd HH:mm').format(task.updatedAt),
                        ].join(' / '),
                      ),
                      isThreeLine: task.memo.isNotEmpty,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PopupMenuButton<String>(
                            onSelected: (value) async {
                              if (value == 'edit') {
                                await onEdit(task);
                              } else if (value == 'delete') {
                                await onDelete(task);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(value: 'edit', child: Text('編集')),
                              PopupMenuItem(value: 'delete', child: Text('削除')),
                            ],
                          ),
                          if (isDesktopLike)
                            ReorderableDragStartListener(
                              index: index,
                              child: dragIcon,
                            )
                          else
                            ReorderableDelayedDragStartListener(
                              index: index,
                              child: dragIcon,
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
