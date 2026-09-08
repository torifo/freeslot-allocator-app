/// The QR hand-off codec, byte-compatible with the hub's `tools/hub/src/qr-codec.ts`.
///
/// A sync document is JSON → gzip → base45 (RFC 9285, so every character is in
/// the QR alphanumeric set) → sliced into `FRL2:<sha16>:<i>:<n>:<crc>:<chunk>`
/// frames. The hub shows the frames as animated QR codes and the phone scans
/// them in whatever order the camera happens to catch them.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

const String _b45 = r'0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';

/// RFC 9285 base45. Two bytes become three characters, a trailing odd byte two.
String base45Encode(List<int> bytes) {
  final out = StringBuffer();
  for (var i = 0; i < bytes.length; i += 2) {
    if (i + 1 < bytes.length) {
      final n = bytes[i] * 256 + bytes[i + 1];
      out
        ..write(_b45[n % 45])
        ..write(_b45[(n ~/ 45) % 45])
        ..write(_b45[n ~/ (45 * 45)]);
    } else {
      final n = bytes[i];
      out
        ..write(_b45[n % 45])
        ..write(_b45[n ~/ 45]);
    }
  }
  return out.toString();
}

/// Inverse of [base45Encode]. Throws [FormatException] on any input the
/// encoder could not have produced — a stray character, an over-large triplet
/// or pair, or a length that leaves a single dangling character.
Uint8List base45Decode(String text) {
  final vals = text.runes.map((r) {
    final v = _b45.indexOf(String.fromCharCode(r));
    if (v < 0) {
      throw FormatException('invalid base45 char ${String.fromCharCode(r)}');
    }
    return v;
  }).toList();
  final out = <int>[];
  for (var i = 0; i < vals.length; i += 3) {
    if (i + 2 < vals.length) {
      final n = vals[i] + vals[i + 1] * 45 + vals[i + 2] * 45 * 45;
      if (n > 0xffff) throw const FormatException('invalid base45 triplet');
      out
        ..add(n >> 8)
        ..add(n & 0xff);
    } else if (i + 1 < vals.length) {
      final n = vals[i] + vals[i + 1] * 45;
      if (n > 0xff) throw const FormatException('invalid base45 pair');
      out.add(n);
    } else {
      throw const FormatException('invalid base45 length');
    }
  }
  return Uint8List.fromList(out);
}

/// CRC-32 (ISO-HDLC) as the hub writes it: uppercase, zero-padded to 8 hex
/// digits. The hub computes it over the UTF-8 bytes of the chunk; chunks are
/// pure ASCII, so `utf8.encode` matches byte for byte.
String crc32Hex(List<int> bytes) =>
    getCrc32(bytes).toRadixString(16).toUpperCase().padLeft(8, '0');

/// Default characters per frame, matching the hub's `CHUNK_CHARS`.
const int kQrChunkChars = 600;

/// Hard ceiling on the frame count, matching the hub's `MAX_FRAMES`. It bounds
/// every allocation driven by a scanned `total`.
const int kMaxQrFrames = 512;

/// What [QrFrameSet.add] made of a scanned frame.
enum QrAddResult {
  /// A new chunk of the payload being collected.
  added,

  /// A chunk already held; the camera simply saw the same code twice.
  duplicate,

  /// The chunk did not match its own CRC — a misread, so ask for it again.
  crcMismatch,

  /// A well-formed frame from a *different* payload (or one that disagrees
  /// about the total). Mixing it in would leave the set forever incomplete.
  differentPayload,

  /// Not an `FRL2` frame at all, or its indices are unusable.
  malformed,
}

/// Collects `FRL2:<sha16>:<i>:<n>:<crc>:<chunk>` frames in any order.
class QrFrameSet {
  /// The 16-hex payload hash of the first accepted frame; every later frame
  /// must agree with it.
  String? hash;

  /// The frame count declared by the first accepted frame.
  int total = 0;

  final Map<int, String> _chunks = <int, String>{};

  /// How many distinct chunks are held.
  int get received => _chunks.length;

  /// Whether every chunk of the payload has been scanned.
  bool get isComplete => total > 0 && _chunks.length == total;

  /// Indices still to scan, in ascending order.
  List<int> get missing => <int>[
    for (var i = 0; i < total; i += 1)
      if (!_chunks.containsKey(i)) i,
  ];

  /// The chunk at [index], or null if it has not been scanned.
  String? chunkAt(int index) => _chunks[index];

  /// Folds one scanned frame into the set.
  QrAddResult add(String frame) {
    // base45's own alphabet contains ':', so only the first five colons are
    // delimiters — splitting into exactly six parts would reject valid frames.
    final parts = frame.split(':');
    if (parts.length < 6 || parts[0] != 'FRL2') return QrAddResult.malformed;
    final chunk = parts.sublist(5).join(':');
    // Decimal digits only: `int.tryParse` would otherwise accept ' 1' and '0x1'.
    if (!RegExp(r'^\d+$').hasMatch(parts[2]) ||
        !RegExp(r'^\d+$').hasMatch(parts[3])) {
      return QrAddResult.malformed;
    }
    final i = int.parse(parts[2]);
    final n = int.parse(parts[3]);
    // Bound `n` before anything sizes itself from it (see [kMaxQrFrames]).
    if (n < 1 || n > kMaxQrFrames || i >= n) return QrAddResult.malformed;
    if (hash != null && (hash != parts[1] || n != total)) {
      return QrAddResult.differentPayload;
    }
    if (crc32Hex(utf8.encode(chunk)) != parts[4]) return QrAddResult.crcMismatch;
    if (hash == null) {
      hash = parts[1];
      total = n;
    }
    if (_chunks.containsKey(i)) return QrAddResult.duplicate;
    _chunks[i] = chunk;
    return QrAddResult.added;
  }

  /// Drops everything so a new payload can be scanned.
  void reset() {
    hash = null;
    total = 0;
    _chunks.clear();
  }
}

/// Reassembles a complete [set] into the JSON object it carries.
///
/// Throws [FormatException] when the set is incomplete, when the base45 or
/// gzip layers are corrupt, when the payload hash disagrees with the frames,
/// or when the payload is not a JSON object.
Map<String, dynamic> decodeQrFrames(QrFrameSet set) {
  if (!set.isComplete) {
    throw FormatException('incomplete: missing ${set.missing}');
  }
  final text = <String>[
    for (var i = 0; i < set.total; i += 1) set.chunkAt(i)!,
  ].join();
  final json = const GZipDecoder().decodeBytes(base45Decode(text));
  final digest = sha256
      .convert(json)
      .toString()
      .substring(0, 16)
      .toUpperCase();
  if (digest != set.hash) {
    throw const FormatException('payload hash mismatch after reassembly');
  }
  final decoded = jsonDecode(utf8.decode(json));
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('payload is not a JSON object: $decoded');
  }
  return decoded;
}

/// Encodes [value] into the same frames the hub would produce.
///
/// The app itself only ever *scans* frames; this exists so the codec can be
/// checked against the hub's fixtures in both directions, and so a future
/// phone→PC QR flow has the encoder ready.
List<String> encodeQrFrames(
  Object? value, {
  int chunkChars = kQrChunkChars,
  int maxFrames = kMaxQrFrames,
}) {
  if (chunkChars < 1) {
    throw ArgumentError.value(chunkChars, 'chunkChars', 'must be positive');
  }
  final json = utf8.encode(jsonEncode(value));
  final text = base45Encode(const GZipEncoder().encodeBytes(json, level: 9));
  final hash = sha256.convert(json).toString().substring(0, 16).toUpperCase();
  final total = (text.length / chunkChars).ceil().clamp(1, 1 << 30);
  if (total > maxFrames) {
    throw StateError(
      'payload needs $total frames, more than $maxFrames; use LAN sync instead',
    );
  }
  return <String>[
    for (var i = 0; i < total; i += 1)
      _frame(
        hash,
        i,
        total,
        text.substring(
          i * chunkChars,
          ((i + 1) * chunkChars).clamp(0, text.length),
        ),
      ),
  ];
}

String _frame(String hash, int i, int total, String chunk) {
  final frame = 'FRL2:$hash:$i:$total:${crc32Hex(utf8.encode(chunk))}:$chunk';
  // Anything outside the QR alphanumeric set would force byte mode and blow up
  // the code size; a base45 bug is the only way to get here.
  if (!RegExp(r'^[0-9A-Z $%*+\-./:]*$').hasMatch(frame)) {
    throw StateError('frame contains a non-alphanumeric-mode character');
  }
  return frame;
}
