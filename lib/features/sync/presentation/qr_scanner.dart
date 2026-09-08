import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Raw payloads of the codes one camera frame contained.
typedef QrCodesCallback = void Function(List<String> codes);

/// How hard the camera is allowed to work.
///
/// The plugin's default throttles detections to one every 250 ms, which beats
/// against the hub's 200–1000 ms animation: whole frames of the QR sequence
/// slide past between two detections and the user has to wait for another lap.
/// [unrestricted] takes every frame the camera produces, at the cost of some
/// battery — worth it for a transfer the user is standing there waiting for,
/// not for the single code a pairing scan needs.
enum QrScanSpeed { normal, unrestricted }

/// Why the camera preview is not there, in terms a screen can act on.
///
/// The plugin's own [MobileScannerException] never leaves this file: screens
/// should not have to know the plugin to explain themselves in Japanese.
enum QrScannerError { permissionDenied, other }

typedef QrErrorBuilder = Widget Function(BuildContext context, QrScannerError error);

/// The camera, behind a seam.
///
/// `mobile_scanner` needs a platform channel and a real camera, so a widget
/// test that built one would fail before it reached the logic worth testing.
/// Every screen asks for the scanner through [qrScannerProvider] and tests
/// override it with something that hands codes in directly.
final qrScannerProvider = Provider<QrScanner>((ref) => const QrScanner());

class QrScanner {
  const QrScanner();

  /// Whether this build can show a camera preview at all. Linux, Windows and
  /// the web have no supported camera here, so those screens have to offer
  /// something else instead of a black rectangle.
  bool get isAvailable =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  Widget build({
    required QrCodesCallback onCodes,
    QrScanSpeed speed = QrScanSpeed.normal,
    QrErrorBuilder? errorBuilder,
  }) => _MobileScannerView(
    onCodes: onCodes,
    speed: speed,
    errorBuilder: errorBuilder,
  );
}

/// Owns a [MobileScannerController] when — and only when — a non-default
/// detection speed is asked for.
///
/// `MobileScanner` looks after the controller it creates itself: it registers
/// the lifecycle observer, stops on `inactive`, restarts on `resumed`, and
/// disposes at the end. Handing it a controller opts out of all of that (see
/// `_MobileScannerState._initializeController`), so this widget has to do the
/// same work by hand rather than leave the camera running behind a locked
/// screen.
class _MobileScannerView extends StatefulWidget {
  const _MobileScannerView({
    required this.onCodes,
    required this.speed,
    required this.errorBuilder,
  });

  final QrCodesCallback onCodes;
  final QrScanSpeed speed;
  final QrErrorBuilder? errorBuilder;

  @override
  State<_MobileScannerView> createState() => _MobileScannerViewState();
}

class _MobileScannerViewState extends State<_MobileScannerView>
    with WidgetsBindingObserver {
  /// Null when the plugin's own default is fine, in which case `MobileScanner`
  /// creates and owns the controller as usual.
  MobileScannerController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.speed == QrScanSpeed.unrestricted) {
      _controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.unrestricted,
      );
      WidgetsBinding.instance.addObserver(this);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    // `hasCameraPermission` first: starting a camera the user never allowed
    // would throw on every resume.
    if (controller == null || !controller.value.hasCameraPermission) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(controller.start());
      case AppLifecycleState.inactive:
        unawaited(controller.stop());
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        break;
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      WidgetsBinding.instance.removeObserver(this);
      // The child `MobileScanner` unmounts first and stops the camera; what is
      // left is the controller itself, which only its owner may dispose.
      unawaited(controller.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final errorBuilder = widget.errorBuilder;
    return MobileScanner(
      controller: _controller,
      onDetect: (BarcodeCapture capture) {
        final codes = capture.barcodes
            .map((Barcode b) => b.rawValue)
            .whereType<String>()
            .toList();
        if (codes.isNotEmpty) widget.onCodes(codes);
      },
      errorBuilder: errorBuilder == null
          ? null
          : (BuildContext ctx, MobileScannerException error) => errorBuilder(
              ctx,
              error.errorCode == MobileScannerErrorCode.permissionDenied
                  ? QrScannerError.permissionDenied
                  : QrScannerError.other,
            ),
    );
  }
}
