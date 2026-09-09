import 'dart:math';

/// The `window.__FRELOCATOR_HUB__` object the hub injects into index.html.
///
/// Its presence is the whole hub-mode test: the public web build
/// (`app.frelocator.riumu.net`) never carries it, so that build keeps its
/// browser-local `PrefsStateStore` untouched.
class HubMode {
  const HubMode({
    required this.base,
    required this.api,
    required this.hubDeviceId,
    required this.dataFile,
    this.schema = 2,
  });

  /// Path the app is served from, e.g. `/<secret>/app/`.
  final String base;

  /// Path the JSON API sits on, e.g. `/<secret>/api/`.
  final String api;

  /// The hub's own device id, for display.
  final String hubDeviceId;

  /// Absolute path of the `data.json` this browser is editing, for display.
  final String dataFile;

  /// Document schema the hub speaks.
  final int schema;
}

/// 16 lowercase hex characters: the same shape the hub's `X-FRELOCATOR-Web-Id`
/// guard accepts, so a malformed id is a bug here rather than a 403 there.
String randomWebId([Random? random]) {
  final r = random ?? Random.secure();
  return List<String>.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
}
