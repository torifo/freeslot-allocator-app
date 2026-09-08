import 'package:flutter_riverpod/flutter_riverpod.dart';

/// True while a sync is running and the user is watching the progress panel.
///
/// The app reloads its state when it comes back to the foreground, and that
/// reload would fight a sync that is about to write the whole document. The
/// flag lets the reload wait for the sync instead of racing it.
final syncInFlightProvider = NotifierProvider<SyncInFlight, bool>(
  SyncInFlight.new,
);

/// A counter rather than a boolean.
///
/// Two owners can hold a sync open at once — the settings screen behind its
/// sheet and the QR screen it pushed — and with a plain `set(false)` whichever
/// one finished first would clear the flag out from under the other, letting
/// the foreground reload run into a merge that is still writing.
///
/// Callers must capture the notifier *before* their first `await`: once the
/// owning widget is gone `ref.read` throws, and an [end] that never runs wedges
/// the reload in `app.dart` for the rest of the app's life.
class SyncInFlight extends Notifier<bool> {
  int _running = 0;

  @override
  bool build() => _running > 0;

  void begin() {
    _running += 1;
    state = true;
  }

  void end() {
    // Never below zero: an unbalanced `end` must not make the next `begin`
    // invisible to the listener in `app.dart`.
    if (_running > 0) _running -= 1;
    state = _running > 0;
  }
}
