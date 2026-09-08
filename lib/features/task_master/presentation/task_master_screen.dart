import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
        title: const Text('タスク'),
        actions: [
          IconButton(
            // `push`, not `go`, even though /categories is also one of the
            // shell's five branches (M-7). Reached from here it is a detour
            // the user finishes and leaves: pushing it above the shell keeps
            // the task list underneath and gives the screen a back arrow,
            // where `go` would swap the whole branch and strand the user on
            // the 設定 tab. The bottom bar and the rail still reach it as a
            // destination in its own right.
            onPressed: () => context.push('/categories'),
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

          // One empty state for the whole screen (M-3): a list with nothing in
          // it used to say 「まだタスクがありません」 once per section and then
          // again at the bottom, three ways of saying the same nothing.
          final isEmpty = visibleTasks.isEmpty;

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // Three chips, three equal columns (M-4). A Wrap with a
              // half-width override put すべて and やるべきこと on one row and
              // left やりたいこと stranded on its own.
              LayoutBuilder(
                builder: (context, constraints) {
                  const gap = 8.0;
                  final filters = <({String label, TaskKind? kind})>[
                    (label: 'すべて', kind: null),
                    for (final kind in TaskKind.values)
                      (label: kind.label, kind: kind),
                  ];
                  // A narrow phone (or a large text scale) cannot give three
                  // columns enough room for 「やりたいこと」 without cutting the
                  // word short, so there the chips wrap and keep their own
                  // natural widths.
                  if (constraints.maxWidth < 360) {
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: <Widget>[
                        for (final filter in filters)
                          _buildFilterChip(
                            label: filter.label,
                            selected: _filter == filter.kind,
                            onSelected: (_) =>
                                setState(() => _filter = filter.kind),
                          ),
                      ],
                    );
                  }
                  final chipWidth =
                      (constraints.maxWidth - gap * (filters.length - 1)) /
                      filters.length;
                  return Row(
                    children: <Widget>[
                      for (final (index, filter) in filters.indexed)
                        Padding(
                          padding: EdgeInsets.only(left: index == 0 ? 0 : gap),
                          child: _buildFilterChip(
                            label: filter.label,
                            selected: _filter == filter.kind,
                            width: chipWidth,
                            onSelected: (_) =>
                                setState(() => _filter = filter.kind),
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              if (isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      _filter == null
                          ? 'タスクはまだありません。画面右下の追加ボタンから登録してください。'
                          : '${_filter!.label}のタスクはまだありません。画面右下の追加ボタンから登録してください。',
                    ),
                  ),
                )
              else
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
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      this.context,
    ).showSnackBar(SnackBar(content: Text('「${task.title}」を削除しました')));
  }

  Widget _buildFilterChip({
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
    double? width,
  }) {
    final chip = ChoiceChip(
      // `double.infinity` rather than the column width again: the label sits
      // inside the chip's own padding, so repeating the number made every chip
      // wider than its column (M-4). A label too long for the column is cut
      // with an ellipsis rather than wrapping and standing taller than its
      // neighbours.
      label: SizedBox(
        width: width == null ? null : double.infinity,
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
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
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(existing == null ? 'タスクを追加しました' : 'タスクを保存しました'),
                ),
              );
            }
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

/// The first non-blank line of a memo, or null when there is nothing to show.
String? firstMemoLine(String memo) {
  for (final line in memo.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return null;
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
  late int _priority;
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
    _priority = (task?.priority ?? 3).clamp(1, 5);
    _kind = task?.kind ?? TaskKind.mustDo;
    _categoryId = task?.categoryId;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _memoController.dispose();
    _estimatedController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final title = _titleController.text.trim();
    final now = DateTime.now();
    setState(() => _isSaving = true);
    try {
      await widget.onSave(
        TaskMaster(
          id: widget.initialTask?.id ?? generateId('task'),
          title: title,
          kind: _kind,
          priority: _priority,
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
              // Five buttons rather than a free-text number: 優先度 has exactly
              // five legal values, and a text field let 「あ」 or 「99」 through
              // to a silent clamp on save (I-7).
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: '優先度',
                  helperText: '1 がいちばん高い優先度です。あとでドラッグでも調整できます。',
                  // Two lines: at a large text scale the helper used to be cut
                  // off mid-sentence (I-6).
                  helperMaxLines: 2,
                  errorMaxLines: 2,
                ),
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: <ButtonSegment<int>>[
                    for (var value = 1; value <= 5; value += 1)
                      ButtonSegment<int>(value: value, label: Text('$value')),
                  ],
                  selected: <int>{_priority},
                  onSelectionChanged: (selection) =>
                      setState(() => _priority = selection.first),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _estimatedController,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '見積もり時間（分）',
                  helperText: '空欄は 0 分として扱います。',
                  helperMaxLines: 2,
                  errorMaxLines: 2,
                ),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) {
                    return null;
                  }
                  final minutes = int.tryParse(text);
                  if (minutes == null || minutes > 1440) {
                    return '見積もりは 0〜1440 分で入力してください。';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _memoController,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                minLines: 3,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'メモ',
                  // Without this the label floats mid-height against a
                  // multi-line box (M-16).
                  alignLabelWithHint: true,
                ),
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
            // The drag hint is advice about a gesture; with nothing to drag it
            // was just noise above an empty box (M-3).
            if (tasks.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 8),
                child: Text('まだタスクがありません。'),
              )
            else ...[
              const Text('上にあるタスクほど優先度が高くなります。ドラッグで並び替えできます。'),
              const SizedBox(height: 12),
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
                      // The update timestamp told the user nothing they could
                      // act on; the first line of the memo is what they wrote
                      // to remind themselves (I-15 / M-1).
                      subtitle: Text(
                        [
                          categoryNameForTask(task) ?? '未分類',
                          '優先度 ${task.priority}',
                          if (task.estimatedMinutes > 0)
                            '${task.estimatedMinutes}分',
                          ?firstMemoLine(task.memo),
                        ].join(' / '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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
          ],
        ),
      ),
    );
  }
}
