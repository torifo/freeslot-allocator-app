/// Whether this build is being served by the local MCP hub.
///
/// The conditional export is inverted compared with `lan_sync_client.dart`:
/// the web file is the default and `dart:io` picks the stub, so the Android
/// and macOS builds provably contain no `dart:js_interop` code path — the
/// import graph, not a runtime `kIsWeb` check, is what keeps it out.
library;

export 'hub_mode_web.dart' if (dart.library.io) 'hub_mode_stub.dart';
