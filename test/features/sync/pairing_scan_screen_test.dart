import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/core/device_clock.dart';
import 'package:frelocator/features/sync/presentation/pairing_scan_screen.dart';
import 'package:frelocator/features/sync/presentation/qr_scanner.dart';
import 'package:frelocator/services/sync/lan_sync_client.dart';
import 'package:frelocator/services/sync/sync_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_container.dart';

final String _pairUrl =
    'frelocator://pair?host=192.168.1.10&port=47820&fp=${'ab' * 32}&code=123456';

/// A camera-less scanner, so the screen falls back to manual entry — which is
/// the path a widget test can actually drive.
class _NoCameraScanner extends QrScanner {
  const _NoCameraScanner();

  @override
  bool get isAvailable => false;
}

class _FakeLanSyncClient implements LanSyncClient {
  _FakeLanSyncClient({this.error});

  final Object? error;
  PairingInfo? info;
  String? deviceId;
  String? deviceName;

  @override
  Future<PairResult> pair(
    PairingInfo info, {
    required String deviceId,
    required String deviceName,
  }) async {
    this.info = info;
    this.deviceId = deviceId;
    this.deviceName = deviceName;
    if (error != null) throw error!;
    return const PairResult(
      token: 'tok',
      hubDeviceId: 'hub-macos',
      fingerprint: 'CD',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: PairingScanScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<ProviderContainer> _container(_FakeLanSyncClient client) async =>
    testContainer(
      overrides: <Override>[
        qrScannerProvider.overrideWithValue(const _NoCameraScanner()),
        lanSyncClientProvider.overrideWithValue(client),
      ],
    );

void main() {
  testWidgets('a pasted pairing URL pairs and stores the connection', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final client = _FakeLanSyncClient();
    final container = await _container(client);
    await _pump(tester, container);

    expect(find.textContaining('この端末にはカメラがありません'), findsOneWidget);
    await tester.enterText(find.byType(TextField), _pairUrl);
    await tester.tap(find.text('この URL でペアリング'));
    await tester.pumpAndSettle();

    expect(client.info!.host, '192.168.1.10');
    expect(client.info!.port, 47820);
    expect(client.info!.code, '123456');
    // The QR carries lower-case hex; the parser normalises it.
    expect(client.info!.fingerprint, 'AB' * 32);
    // The persisted device id, and a name derived from it.
    final deviceId = container.read(deviceClockProvider).deviceId;
    expect(client.deviceId, deviceId);
    expect(client.deviceName, 'FRELOCATOR ($deviceId)');

    final saved = await SyncSettingsStore().load();
    expect(saved.isPaired, isTrue);
    expect(saved.host, '192.168.1.10');
    expect(saved.token, 'tok');
    expect(saved.hubDeviceId, 'hub-macos');
    // The pin the hub confirmed, not the one from the QR.
    expect(saved.fingerprint, 'CD');
  });

  testWidgets('a URL that is not a pairing QR is refused before any request', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final client = _FakeLanSyncClient();
    await _pump(tester, await _container(client));

    await tester.enterText(find.byType(TextField), 'https://example.com/');
    await tester.tap(find.text('この URL でペアリング'));
    await tester.pumpAndSettle();

    expect(find.text('ペアリング用の QR ではありません'), findsOneWidget);
    expect(client.info, isNull);
    expect((await SyncSettingsStore().load()).isPaired, isFalse);
  });

  testWidgets('a hub error is shown in Japanese, never in the hub words', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final client = _FakeLanSyncClient(
      error: const SyncHttpException(403, 'pairing_failed', 'pairing code rejected'),
    );
    await _pump(tester, await _container(client));

    await tester.enterText(find.byType(TextField), _pairUrl);
    await tester.tap(find.text('この URL でペアリング'));
    await tester.pumpAndSettle();

    expect(find.text(syncErrorMessage('pairing_failed')), findsOneWidget);
    expect(find.textContaining('pairing code rejected'), findsNothing);
    expect((await SyncSettingsStore().load()).isPaired, isFalse);
  });
}
