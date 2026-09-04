import 'package:flutter/material.dart';

/// Message shown in a SnackBar when a save fails for a reason that is not a
/// domain validation error (those already carry a Japanese message).
const String saveFailureMessage = '保存に失敗しました。もう一度お試しください。';

/// Shared error state for `AsyncValue.when(error: ...)` branches.
///
/// Shows a short Japanese message and a 再試行 button that lets the caller
/// invalidate the failing provider.
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.onRetry,
    this.message = 'データの読み込みに失敗しました',
  });

  final VoidCallback onRetry;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('再試行')),
          ],
        ),
      ),
    );
  }
}
