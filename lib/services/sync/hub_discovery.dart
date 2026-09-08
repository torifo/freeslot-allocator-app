/// mDNS discovery of the hub, picked per platform: a real `_frelocator._tcp`
/// lookup where `dart:io` exists, and a no-op on the web.
library;

export 'hub_discovery_stub.dart' if (dart.library.io) 'hub_discovery_io.dart';
