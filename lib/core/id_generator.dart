import 'dart:math';

/// Random source for the entropy suffix of generated identifiers.
final Random _random = Random.secure();

/// Generates a locally unique identifier of the form
/// `<prefix>-<microsecondsSinceEpoch>-<6 random hex chars>`.
///
/// The timestamp keeps identifiers roughly sortable by creation time, while the
/// random suffix removes the collision risk of two identifiers being created in
/// the same microsecond (rapid taps, loops that copy many records at once).
/// Identifiers created by older builds are plain strings and remain valid.
String generateId(String prefix) {
  final micros = DateTime.now().microsecondsSinceEpoch;
  final buffer = StringBuffer();
  for (var index = 0; index < 6; index += 1) {
    buffer.write(_random.nextInt(16).toRadixString(16));
  }
  return '$prefix-$micros-$buffer';
}
