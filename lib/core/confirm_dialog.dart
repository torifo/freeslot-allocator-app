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

/// The same gate for a destructive action that is not a 削除 — restoring a
/// backup over the current data, or dropping a paired connection.
///
/// [confirmDelete] hard-codes 「削除」 in its title and button, which would be a
/// lie on those screens; the shape of the dialog is what matters, not the verb.
///
/// Returns `true` only when the user explicitly taps [confirmLabel].
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = true,
}) async {
  final colorScheme = Theme.of(context).colorScheme;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: colorScheme.error,
                  foregroundColor: colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
