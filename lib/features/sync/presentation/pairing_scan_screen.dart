import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/device_clock.dart';
import '../../../services/sync/lan_sync_client.dart';
import '../../../services/sync/sync_settings.dart';
import 'qr_scanner.dart';

/// Reads the hub's pairing QR (`frelocator://pair?host=…&port=…&fp=…&code=…`)
/// and trades the one-shot code for this device's long-lived token.
///
/// The same URL can be typed in by hand: on a machine without a camera that is
/// the only way in, and on a phone it rescues a QR the camera cannot focus on.
class PairingScanScreen extends ConsumerStatefulWidget {
  const PairingScanScreen({super.key});

  @override
  ConsumerState<PairingScanScreen> createState() => _PairingScanScreenState();
}

class _PairingScanScreenState extends ConsumerState<PairingScanScreen> {
  final TextEditingController _manual = TextEditingController();

  bool _busy = false;
  bool _manualEntry = false;
  String? _error;

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  /// One code per camera frame is enough: pairing needs exactly one URL, and
  /// [_pair] is guarded by `_busy` anyway.
  ///
  /// Returning the future rather than dropping it keeps `_pair`'s errors inside
  /// `_pair` — where the catch-all turns them into a message on screen — rather
  /// than surfacing as an unhandled async error from a camera callback.
  Future<void> _onCodes(List<String> codes) async {
    if (codes.isEmpty) return;
    await _pair(codes.first);
  }

  Future<void> _pair(String raw) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final info = PairingInfo.parse(raw.trim());
      // The persisted device id, never a fresh one: the hub keys the token and
      // the purge cut-off on it, and a new id every pairing would look like a
      // new phone each time.
      final deviceId = ref.read(deviceClockProvider).deviceId;
      final deviceName = 'FRELOCATOR ($deviceId)';
      final result = await ref
          .read(lanSyncClientProvider)
          .pair(info, deviceId: deviceId, deviceName: deviceName);
      await ref.read(syncSettingsStoreProvider).save(
        SyncSettings(
          host: info.host,
          port: info.port,
          fingerprint: result.fingerprint,
          token: result.token,
          hubDeviceId: result.hubDeviceId,
          deviceName: deviceName,
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ペアリングしました')),
      );
      Navigator.of(context).pop();
      return;
    } on FormatException catch (error) {
      _fail(error.message);
    } on SyncHttpException catch (error) {
      // Never the hub's own `message`: it is English and written for logs.
      _fail(syncErrorMessage(error.code));
    } catch (_) {
      // A socket, a platform channel, shared_preferences: anything the two
      // clauses above did not name. Without this the screen would sit at 「読み
      // 取り中」 with `_busy` stuck true and no way back but the back arrow.
      _fail(syncErrorMessage('unknown'));
    } finally {
      // `_fail` already cleared it on every error path; this covers the one
      // where the widget went away mid-request and `_fail` returned early.
      _busy = false;
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scanner = ref.read(qrScannerProvider);
    final useScanner = scanner.isAvailable && !_manualEntry;
    return Scaffold(
      appBar: AppBar(title: const Text('PC とペアリング')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              scanner.isAvailable
                  ? 'PC の Claude Code で sync_status を実行し、lan.pairingPage の URL を開いて、'
                    '表示された QR を読み取ります。カメラはこの QR の読み取りにだけ使います。'
                  : 'この端末にはカメラがありません。PC の sync_status の lan.pairingPage を開き、'
                    'ページに表示されている frelocator://pair… の URL を貼り付けてください。',
            ),
          ),
          if (useScanner)
            Expanded(child: scanner.build(onCodes: _onCodes))
          else
            _manualForm(),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (scanner.isAvailable && !_manualEntry)
            TextButton(
              onPressed: () => setState(() => _manualEntry = true),
              child: const Text('URL を手入力'),
            ),
        ],
      ),
    );
  }

  Widget _manualForm() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: _manual,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'ペアリング URL',
            hintText: 'frelocator://pair?host=…',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : () => _pair(_manual.text),
          child: const Text('この URL でペアリング'),
        ),
      ],
    ),
  );
}
