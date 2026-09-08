import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Raw payloads of the codes one camera frame contained.
typedef QrCodesCallback = void Function(List<String> codes);

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

  Widget build({required QrCodesCallback onCodes}) => MobileScanner(
    onDetect: (BarcodeCapture capture) {
      final codes = capture.barcodes
          .map((Barcode b) => b.rawValue)
          .whereType<String>()
          .toList();
      if (codes.isNotEmpty) onCodes(codes);
    },
  );
}
