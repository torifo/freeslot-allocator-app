import 'package:flutter/material.dart';

/// Shows a Japanese confirmation dialog before an irreversible delete.
///
/// Returns `true` only when the user explicitly taps 削除.
Future<bool> confirmDelete(
  BuildContext context, {
  required String name,
  String? description,
}) async {
  final colorScheme = Theme.of(context).colorScheme;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('削除の確認'),
      content: Text(
        description == null
            ? '「$name」を削除しますか？'
            : '「$name」を削除しますか？\n$description',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: colorScheme.error,
            foregroundColor: colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('削除'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
