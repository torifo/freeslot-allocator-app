import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/sync/qr_chunk_codec.dart';
import '../../../services/sync/sync_progress.dart';
import '../../../services/sync/sync_service.dart';
import '../../daily_plan/application/daily_plan_controller.dart';
import '../../task_master/application/task_master_controller.dart';
import 'qr_scanner.dart';
import 'sync_progress_panel.dart';

/// Collects the hub's animated QR frames and merges the document they carry.
///
/// The frames repeat forever and arrive in whatever order the camera catches
/// them, so the screen just keeps folding whatever it sees into a [QrFrameSet]
/// until the set is complete.
class QrReceiveScreen extends ConsumerStatefulWidget {
  const QrReceiveScreen({super.key});

  @override
  ConsumerState<QrReceiveScreen> createState() => _QrReceiveScreenState();
}

class _QrReceiveScreenState extends ConsumerState<QrReceiveScreen> {
  final QrFrameSet _frames = QrFrameSet();
  final SyncProgressController _progress = SyncProgressController();

  /// True once the set is complete: the camera keeps firing while the merge
  /// runs, and a second pass through [_ingest] would apply it twice.
  bool _done = false;
  bool _busy = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    _progress.start(SyncKind.qr);
    _progress.stage(SyncStage.scanning);
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  Future<void> _ingest(List<String> codes) async {
    if (_done || _busy) return;
    _busy = true;
    try {
      for (final raw in codes) {
        final result = _frames.add(raw);
        if (result == QrAddResult.differentPayload) {
          if (!await _askRestart()) continue;
          _frames.reset();
          _frames.add(raw);
        } else if (result == QrAddResult.crcMismatch) {
          _note = '読み取りエラーのコマを捨てました。そのコマをもう一度写してください。';
        }
        _progress.frames(
          received: _frames.received,
          total: _frames.total,
          missing: _frames.missing,
        );
        if (_frames.isComplete) {
          _done = true;
          await _apply();
          return;
        }
      }
    } finally {
      _busy = false;
    }
    if (mounted) setState(() {});
  }

  /// A frame from another payload cannot be mixed in: the set would never
  /// complete. Ask before throwing away what has been scanned so far.
  Future<bool> _askRestart() async {
    final restart = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('別のデータです'),
        content: const Text('これまでに読み取ったコマを捨てて、最初からやり直しますか？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('いいえ'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('やり直す'),
          ),
        ],
      ),
    );
    return restart ?? false;
  }

  Future<void> _apply() async {
    _progress.stage(SyncStage.decoding);
    final Map<String, dynamic> json;
    try {
      json = decodeQrFrames(_frames);
    } on FormatException catch (error) {
      _progress.fail('corrupt', error.message);
      if (mounted) setState(() {});
      return;
    }
    final outcome = await ref
        .read(syncServiceProvider)
        .applyReceived(json, progress: _progress);
    if (outcome is SyncApplied) {
      ref.invalidate(taskMasterControllerProvider);
      ref.invalidate(dailyPlanControllerProvider);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scanner = ref.read(qrScannerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('QR で受け取る')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              scanner.isAvailable
                  ? 'PC の Claude Code で sync_status を実行し、lan.qrPage の URL を開いて、'
                    'その画面にカメラを向け続けてください。コマは繰り返し表示されるので、順番は気にしなくて大丈夫です。'
                  : 'この端末にはカメラがないため QR では受け取れません。'
                    'PC の「ファイルから取り込む」か LAN 同期を使ってください。',
            ),
          ),
          if (scanner.isAvailable && !_done)
            Expanded(child: scanner.build(onCodes: _ingest))
          else
            const Spacer(),
          SyncProgressPanel(
            controller: _progress,
            onCancel: () => Navigator.of(context).pop(),
            onClose: () => Navigator.of(context).pop(),
          ),
          if (_note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12, left: 12, right: 12),
              child: Text(_note!, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}
