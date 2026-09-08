import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/sync/sync_progress.dart';

String stageLabel(SyncStage s) => switch (s) {
  SyncStage.idle => '待機中',
  SyncStage.connecting => '接続中',
  SyncStage.sending => '送信中',
  SyncStage.waitingHub => 'PC で処理中',
  SyncStage.receiving => '受信中',
  SyncStage.applying => 'マージ中',
  SyncStage.saving => '保存中',
  SyncStage.done => '完了',
  SyncStage.cancelled => '中止しました',
  SyncStage.failed => '失敗',
  SyncStage.scanning => '読み取り中',
  SyncStage.decoding => '復元中',
};

/// 追加 / 更新 / 削除 / 消去 / 警告.
///
/// `削除` are records that stay as tombstones; `消去` (`removed`) are the ones
/// the hub dropped outright when it purged. Folding the two together would
/// tell the user that data still on the hub is gone.
/// How many frame numbers the 未受信 line spells out before it gives up.
///
/// Early in a 500-frame transfer nearly everything is missing, and a line that
/// listed all of them would push the buttons off the screen while telling the
/// user nothing they cannot see in the grid above it.
const int kMissingFramesShown = 12;

String missingFramesLine(List<int> missing) {
  final shown = missing.take(kMissingFramesShown).map((i) => i + 1).join(', ');
  final rest = missing.length - kMissingFramesShown;
  return rest > 0 ? '未受信: $shown 他 $rest コマ' : '未受信: $shown';
}

String summaryLine(SyncSummary s) =>
    '追加 ${s.added} / 更新 ${s.updated} / 削除 ${s.deleted} / 消去 ${s.removed} / 警告 ${s.warnings}';

/// The panel bound to a [SyncProgressController]. It shows only numbers that
/// can actually be measured; the hub-side stage is an indeterminate bar.
///
/// It re-renders once a second so the elapsed time keeps moving even while the
/// controller itself is quiet.
class SyncProgressPanel extends StatefulWidget {
  const SyncProgressPanel({
    super.key,
    required this.controller,
    required this.onCancel,
    required this.onClose,
    this.scrollable = true,
  });

  final SyncProgressController controller;
  final VoidCallback onCancel;
  final VoidCallback onClose;

  /// Whether the panel scrolls its own body.
  ///
  /// True in the modal sheet, where the panel is the whole route and a 500-frame
  /// grid would otherwise run off the bottom of the screen. False when the panel
  /// is already inside a scrolling list (the QR screen), because a scrollable
  /// nested in a scrollable fights the user's finger for the gesture.
  final bool scrollable;

  @override
  State<SyncProgressPanel> createState() => _SyncProgressPanelState();
}

class _SyncProgressPanelState extends State<SyncProgressPanel> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_retimeTicker);
    _retimeTicker();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_retimeTicker);
    _ticker?.cancel();
    super.dispose();
  }

  /// The clock only runs while there is something to wait for. A timer left
  /// ticking behind a finished sync would rebuild the panel forever — and
  /// would keep `pumpAndSettle` from ever settling in a widget test.
  void _retimeTicker() {
    final active = widget.controller.value.isActive;
    if (active && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!active && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<SyncProgress>(
      valueListenable: widget.controller,
      builder: (context, p, _) {
        final now = DateTime.now().toUtc();
        final detail = _detail(p);
        final body = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(stageLabel(p.stage), style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              // Indeterminate only while something is actually running: a bar
              // still sweeping under 「失敗」 or 「中止しました」 reads as work
              // that has not stopped yet.
              Semantics(
                label: '同期の進み具合',
                value: stageLabel(p.stage),
                child: LinearProgressIndicator(
                  value: p.isActive ? p.fraction : (p.fraction ?? 0),
                ),
              ),
              const SizedBox(height: 8),
              if (detail.isNotEmpty)
                Text(detail, style: theme.textTheme.bodySmall),
              Text(
                '経過 ${p.elapsed(now).inSeconds} 秒'
                '${p.isSlow(now) ? '（時間がかかっています）' : ''}',
                style: theme.textTheme.bodySmall,
              ),
              if (p.kind == SyncKind.qr && p.framesTotal > 0) ...<Widget>[
                const SizedBox(height: 8),
                _FrameGrid(progress: p),
                if (p.missingFrames.isNotEmpty)
                  Text(
                    missingFramesLine(p.missingFrames),
                    style: theme.textTheme.bodySmall,
                  ),
              ],
              if (p.stage == SyncStage.done && p.summary != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(summaryLine(p.summary!)),
              ],
              if (p.stage == SyncStage.failed)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  // Already the Japanese `syncErrorMessage` text: the hub's own
                  // English message never reaches this widget.
                  child: Text(
                    p.errorMessage ?? '',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              if (p.stage == SyncStage.cancelled && p.hubMayHaveChanged)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('PC は更新済みの可能性があります。この端末への反映だけ中止しました。'),
                ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  // Saving is the one stage that must finish: stopping halfway
                  // through the write is what a cancel must never do.
                  if (p.isActive && p.stage != SyncStage.saving)
                    TextButton(
                      onPressed: widget.onCancel,
                      child: const Text('キャンセル'),
                    ),
                  if (!p.isActive)
                    FilledButton(
                      onPressed: widget.onClose,
                      child: const Text('閉じる'),
                    ),
                ],
              ),
            ],
          );
        return Padding(
          padding: const EdgeInsets.all(20),
          child: widget.scrollable
              ? ConstrainedBox(
                  // A QR transfer can carry up to 512 frames; the grid plus the
                  // 未受信 line would run off a phone screen without this.
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.6,
                  ),
                  child: SingleChildScrollView(child: body),
                )
              : body,
        );
      },
    );
  }

  String _detail(SyncProgress p) => switch (p.stage) {
    SyncStage.sending when p.totalBytes != null =>
      '${_kb(p.sentBytes)} / ${_kb(p.totalBytes!)}',
    SyncStage.receiving => '${_kb(p.receivedBytes)} 受信',
    SyncStage.waitingHub => 'PC がマージしています（進捗は計測できません）',
    SyncStage.scanning => '${p.framesReceived} / ${p.framesTotal} コマ受信',
    _ => '',
  };

  String _kb(int b) => '${(b / 1024).toStringAsFixed(1)} KB';
}

/// One square per QR frame, filled once that frame has been scanned, so the
/// user can see which part of the animation they still have to catch.
class _FrameGrid extends StatelessWidget {
  const _FrameGrid({required this.progress});

  final SyncProgress progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The number inside each square is scaled by the user's text setting, so
    // the square has to grow with it or the digits are clipped.
    final side = MediaQuery.textScalerOf(context).scale(18).clamp(18.0, 48.0);
    // `contains` on a list is linear; with 512 frames the grid would do a
    // quarter of a million comparisons on every rebuild.
    final missing = progress.missingFrames.toSet();
    return Semantics(
      container: true,
      label:
          'コマの受信状況 ${progress.framesReceived} / ${progress.framesTotal}',
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: <Widget>[
          for (var i = 0; i < progress.framesTotal; i += 1)
            Semantics(
              label: '${i + 1} コマ目 ${missing.contains(i) ? '未受信' : '受信済み'}',
              excludeSemantics: true,
              child: Container(
                width: side,
                height: side,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: missing.contains(i)
                      ? scheme.surfaceContainerHighest
                      : scheme.primary,
                ),
                child: Text(
                  '${i + 1}',
                  style: TextStyle(
                    fontSize: 9,
                    color: missing.contains(i)
                        ? scheme.onSurface
                        : scheme.onPrimary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
