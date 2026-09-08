import 'package:flutter_riverpod/flutter_riverpod.dart';

/// True while a sync is running and the user is watching the progress panel.
///
/// The app reloads its state when it comes back to the foreground, and that
/// reload would fight a sync that is about to write the whole document. The
/// flag lets the reload wait for the sync instead of racing it.
final syncInFlightProvider = NotifierProvider<SyncInFlight, bool>(
  SyncInFlight.new,
);

class SyncInFlight extends Notifier<bool> {
  @override
  bool build() => false;

  void update({required bool running}) => state = running;
}
