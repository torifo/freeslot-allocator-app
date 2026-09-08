import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/sync/lan_sync_types.dart';
import '../../../services/sync/qr_chunk_codec.dart';
import '../../../services/sync/sync_progress.dart';
import '../../../services/sync/sync_service.dart';
import '../../daily_plan/application/daily_plan_controller.dart';
import '../../task_master/application/task_master_controller.dart';
import '../application/sync_in_flight.dart';
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

class _QrReceiveScreenState extends ConsumerState<QrReceiveScreen>
    with WidgetsBindingObserver {
  final QrFrameSet _frames = QrFrameSet();
  final SyncProgressController _progress = SyncProgressController();

  /// True once the set is complete: the camera keeps firing while the merge
  /// runs, and a second pass through [_ingest] would apply it twice. Reset when
  /// the merge fails, so the user can simply keep scanning.
  bool _done = false;
  bool _busy = false;
  String? _note;

  /// True once the camera has reported it cannot run. The progress ticker is
  /// stopped at the same time: a scan that can never start is a failure, not a
  /// slow one, and the panel used to sit there saying 「時間がかかっています」
  /// under a permission error (I-9).
  bool _cameraFailed = false;

  /// Bumped on every retry so the scanner subtree is built fresh: reusing the
  /// old element would leave the plugin sitting on the camera it already
  /// failed to open.
  int _scanAttempt = 0;

  /// The other way of getting the data across, named for the platform the user
  /// is actually holding rather than for both at once.
  String get _fallbackAction =>
      !kIsWeb && Platform.isMacOS ? '「ファイルから取り込む」' : '「PC へ書き出す」';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _progress.start(SyncKind.qr);
    _progress.stage(SyncStage.scanning);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _progress.dispose();
    super.dispose();
  }

  /// Coming back from the settings app is the usual way a camera permission
  /// gets granted, so the screen tries again by itself rather than making the
  /// user find the button.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _cameraFailed) {
      _retryCamera();
    }
  }

  /// Puts the camera back in play after it refused to start (I-2).
  ///
  /// The panel is started over rather than left saying 失敗: the user asked for
  /// another attempt, and a stale failure under a live preview reads as if the
  /// retry did nothing.
  void _retryCamera() {
    if (!_cameraFailed) return;
    setState(() {
      _cameraFailed = false;
      _scanAttempt += 1;
    });
    _progress.start(SyncKind.qr);
    _progress.stage(SyncStage.scanning);
  }

  Future<void> _ingest(List<String> codes) async {
    if (_done || _busy) return;
    _busy = true;
    // A frame arriving after a failed attempt is the user starting over; the
    // panel must stop saying 失敗 rather than count frames under it.
    if (_progress.value.stage == SyncStage.failed) {
      _progress.start(SyncKind.qr);
      _progress.stage(SyncStage.scanning);
    }
    // The note is carried through the loop rather than written straight to the
    // field: a frame that decodes cleanly after a misread means the camera is
    // reading again, and the warning should go away with it.
    String? note = _note;
    try {
      for (final raw in codes) {
        final result = _frames.add(raw);
        switch (result) {
          case QrAddResult.differentPayload:
            if (!await _askRestart()) continue;
            _frames.reset();
            _frames.add(raw);
            note = null;
          case QrAddResult.crcMismatch:
            note = '読み取りエラーのコマを捨てました。そのコマをもう一度写してください。';
          case QrAddResult.added:
            note = null;
          case QrAddResult.duplicate:
          // Not this payload's frame shape at all (a QR from something else
          // entirely): nothing to say, the user is simply pointing at the
          // wrong thing and the counter below will not move.
          case QrAddResult.malformed:
            break;
        }
        _progress.frames(
          received: _frames.received,
          total: _frames.total,
          missing: _frames.missing,
        );
        if (_frames.isComplete) {
          _done = true;
          if (mounted) setState(() => _note = note);
          await _apply();
          return;
        }
      }
    } finally {
      _busy = false;
    }
    if (mounted) setState(() => _note = note);
  }

  /// A frame from another payload cannot be mixed in: the set would never
  /// complete. Ask before throwing away what has been scanned so far.
  Future<bool> _askRestart() async {
    // The camera can deliver a frame in the same turn the route is popped.
    if (!mounted) return false;
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
    if (!mounted) return;
    // Captured before the first await. `ref` belongs to this widget, and the
    // merge outlives a user who backs out of the screen half way through it —
    // `ref.read` would then throw and leave the in-flight flag raised forever.
    final container = ProviderScope.containerOf(context, listen: false);
    final inFlight = container.read(syncInFlightProvider.notifier);

    _progress.stage(SyncStage.decoding);
    final Map<String, dynamic> json;
    try {
      json = decodeQrFrames(_frames);
    } on FormatException catch (error) {
      _progress.fail('corrupt', error.message);
      _rescanable();
      return;
    }

    inFlight.begin();
    final SyncOutcome outcome;
    try {
      outcome = await container
          .read(syncServiceProvider)
          .applyReceived(json, progress: _progress);
    } catch (_) {
      _progress.fail('unknown', syncErrorMessage('unknown'));
      _rescanable();
      return;
    } finally {
      inFlight.end();
    }

    switch (outcome) {
      case SyncApplied():
        container.invalidate(taskMasterControllerProvider);
        container.invalidate(dailyPlanControllerProvider);
        if (mounted) setState(() {});
      // Nothing was written, so the scanned set is worth nothing either: let
      // the camera come back rather than stranding the user on a dead panel.
      case SyncFailed():
      case SyncCancelled():
      case SyncNeedsReplace():
        _rescanable();
    }
  }

  /// Puts the screen back in a state where scanning again can work.
  void _rescanable() {
    _done = false;
    _frames.reset();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scanner = ref.read(qrScannerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('QR で受け取る')),
      // A list rather than a Column: the frame grid grows with the number of
      // frames the hub chose, and 200+ of them must scroll rather than overflow.
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          Text(
            scanner.isAvailable
                // No tool names here: `sync_status` and `lan.qrPage` belong to
                // the hub's own guide (`McpGuideSection`), not to the screen a
                // phone user is standing in front of (C-1).
                ? 'PC 側で QR 画面を開き、この画面のカメラを向け続けてください。'
                  '（PC の Claude Code をお使いの場合は「PC と同期」の案内を参照）\n'
                  'コマは繰り返し表示されるので、順番は気にしなくて大丈夫です。'
                : 'この端末にはカメラがないため QR では受け取れません。'
                  '$_fallbackActionか LAN 同期を使ってください。',
          ),
          // Rendered while the camera is failing too: the explanation of what
          // went wrong belongs where the preview would have been, next to the
          // button that tries again (I-2).
          if (scanner.isAvailable && !_done) ...<Widget>[
            const SizedBox(height: 12),
            SizedBox(
              // A fixed slice of the screen rather than a square: the panel
              // underneath carries the frame counter the user is watching, and
              // a preview that filled the width would push it off the bottom.
              height: (MediaQuery.sizeOf(context).height * 0.45)
                  .clamp(160.0, 420.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: KeyedSubtree(
                  key: ValueKey<int>(_scanAttempt),
                  child: scanner.build(
                    onCodes: _ingest,
                    // The hub flips frames every 200–1000 ms; the plugin's
                    // default 250 ms throttle would drop whole frames of that
                    // animation.
                    speed: QrScanSpeed.unrestricted,
                    errorBuilder: _cameraError,
                  ),
                ),
              ),
            ),
            if (_cameraFailed)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: FilledButton.icon(
                  onPressed: _retryCamera,
                  icon: const Icon(Icons.refresh),
                  label: const Text('もう一度試す'),
                ),
              ),
          ],
          SyncProgressPanel(
            controller: _progress,
            // Cancel stops the transfer and leaves the panel saying so; it is
            // not a way out of the screen — the back arrow is.
            onCancel: _progress.cancel,
            onClose: () => Navigator.of(context).pop(),
            scrollable: false,
          ),
          if (_note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12, left: 8, right: 8),
              child: Text(_note!, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  Widget _cameraError(BuildContext context, QrScannerError error) {
    // No `openAppSettings` here: `permission_handler` is not a dependency of
    // this app, and the other two routes work today.
    final message = error == QrScannerError.permissionDenied
        ? 'カメラの使用が許可されていません。\n'
              '端末の設定アプリでこのアプリのカメラを許可するか、'
              '$_fallbackActionか LAN 同期を使ってください。'
        : '${syncErrorMessage('camera')}\n$_fallbackActionか LAN 同期を使ってください。';
    // Reported during a build, so the panel is moved to 失敗 after this frame
    // rather than inside it.
    if (!_cameraFailed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _cameraFailed) return;
        setState(() => _cameraFailed = true);
        _progress.fail('camera', message);
      });
    }
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(message, textAlign: TextAlign.center),
        ),
      ),
    );
  }
}
