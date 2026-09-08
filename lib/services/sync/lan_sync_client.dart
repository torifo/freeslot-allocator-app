/// The LAN sync client, picked per platform: the real pinned-HTTPS client on
/// mobile and desktop, a refusing stub on the web where `dart:io` is absent.
library;

export 'lan_sync_client_stub.dart' if (dart.library.io) 'lan_sync_client_io.dart';
