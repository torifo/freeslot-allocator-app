import 'hub_mode_types.dart';

export 'hub_mode_types.dart';

/// Always null off the web: the phone and macOS builds keep their existing
/// `PrefsStateStore` / `FileBackedStore` path untouched.
HubMode? readHubMode() => null;

String? readWebId() => null;

void saveWebId(String id) {}

/// Only the browser has an origin to resolve API URLs against.
String? readOrigin() => null;

/// Nothing off the web is ever hidden, so the poller would never pause.
bool documentVisible() => true;

/// Returns the remover, so the caller's `dispose` has the same shape here as
/// on the web.
void Function() addVisibilityListener(void Function(bool visible) listener) => () {};

void Function() setUnloadGuard(bool Function() hasUnsentEdits) => () {};

/// Never reached off the web; minted anyway so the signature matches.
String ensureWebId() => randomWebId();
