import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/services/sync/qr_chunk_codec.dart';

/// Fixtures written by the hub's own encoder (`tools/hub/src/qr-codec.ts`), so
/// these tests fail the moment the two implementations drift apart.
Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/qr_frames/$name.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('base45 vectors (RFC 9285)', () {
    expect(base45Encode(utf8.encode('AB')), 'BB8');
    expect(base45Encode(utf8.encode('Hello!!')), '%69 VD92EX0');
    expect(utf8.decode(base45Decode('QED8WEX0')), 'ietf!');
    expect(() => base45Decode('GGW'), throwsFormatException);
    expect(() => base45Decode('::'), throwsFormatException);
    expect(() => base45Decode('0'), throwsFormatException);
    expect(() => base45Decode('#'), throwsFormatException);
  });

  test('the empty string is the encoding of no bytes, and decodes back', () {
    expect(base45Encode(const <int>[]), '');
    expect(base45Decode(''), isEmpty);
  });

  test('base45 round-trips every byte, odd and even lengths alike', () {
    final bytes = <int>[for (var i = 0; i < 256; i += 1) i];
    expect(base45Decode(base45Encode(bytes)), bytes);
    expect(base45Decode(base45Encode(bytes.sublist(1))), bytes.sublist(1));
  });

  test('crc32 check value', () {
    expect(crc32Hex(utf8.encode('123456789')), 'CBF43926');
  });

  for (final name in const <String>['sample', 'colon_chunks']) {
    group('fixture $name', () {
      final fixture = _fixture(name);
      final frames = (fixture['frames'] as List).cast<String>();

      test('decodes frames produced by the TypeScript hub, in any order', () {
        final set = QrFrameSet();
        for (final f in frames.reversed) {
          expect(set.add(f), QrAddResult.added);
        }
        expect(set.isComplete, isTrue);
        expect(set.received, frames.length);
        expect(set.missing, isEmpty);
        expect(decodeQrFrames(set), fixture['value']);
      });

      test('re-encodes to the same frames the hub produced', () {
        expect(
          encodeQrFrames(fixture['value'], chunkChars: fixture['chunkChars'] as int),
          frames,
        );
      });

      test('a Dart round-trip reproduces the document', () {
        final set = QrFrameSet();
        for (final f in encodeQrFrames(
          fixture['value'],
          chunkChars: fixture['chunkChars'] as int,
        )) {
          expect(set.add(f), QrAddResult.added);
        }
        expect(decodeQrFrames(set), fixture['value']);
      });
    });
  }

  test('the hub splits chunks across ":" characters, which stay in the chunk', () {
    // base45's alphabet contains ':', so a naive `split(':')` parser would
    // corrupt these frames. Guard that the fixture still exercises that case.
    final frames = (_fixture('colon_chunks')['frames'] as List).cast<String>();
    expect(
      frames.where((f) => f.split(':').sublist(5).join(':').contains(':')),
      isNotEmpty,
    );
  });

  test('reports duplicates, crc mismatch and foreign payloads', () {
    final frames = (_fixture('sample')['frames'] as List).cast<String>();
    final set = QrFrameSet();
    expect(set.add(frames[0]), QrAddResult.added);
    expect(set.add(frames[0]), QrAddResult.duplicate);
    expect(set.missing, hasLength(frames.length - 1));

    final bad =
        '${frames[1].substring(0, frames[1].length - 1)}'
        '${frames[1].endsWith('A') ? 'B' : 'A'}';
    expect(set.add(bad), QrAddResult.crcMismatch);

    expect(
      set.add('FRL2:0000000000000000:0:1:00000000:AB'),
      QrAddResult.differentPayload,
    );
    // A frame that disagrees about the total would leave the set permanently
    // incomplete, so it is refused as well.
    expect(
      set.add('FRL2:${set.hash}:1:${frames.length + 1}:00000000:AB'),
      QrAddResult.differentPayload,
    );

    expect(set.add('garbage'), QrAddResult.malformed);
    expect(set.add('FRL1:${set.hash}:0:1:00000000:AB'), QrAddResult.malformed);
    // Non-decimal indices and totals, and totals above the hub's MAX_FRAMES.
    expect(set.add('FRL2:${set.hash}: 1:3:00000000:AB'), QrAddResult.malformed);
    expect(
      set.add('FRL2:${set.hash}:0:2000000000:00000000:AB'),
      QrAddResult.malformed,
    );
    expect(
      set.add('FRL2:${set.hash}:0:${kMaxQrFrames + 1}:00000000:AB'),
      QrAddResult.malformed,
    );
    // i must be inside the declared total.
    expect(set.add('FRL2:${set.hash}:3:3:00000000:AB'), QrAddResult.malformed);

    expect(() => decodeQrFrames(set), throwsFormatException);
    set.reset();
    expect(set.hash, isNull);
    expect(set.total, 0);
    expect(set.received, 0);
  });

  test('chunks containing ":" round-trip through the frame parser', () {
    const colonChunk = 'A:B';
    final colonFrame =
        'FRL2:0123456789ABCDEF:0:1:${crc32Hex(utf8.encode(colonChunk))}'
        ':$colonChunk';
    final colonSet = QrFrameSet();
    expect(colonSet.add(colonFrame), QrAddResult.added);
    expect(colonSet.chunkAt(0), colonChunk);
  });

  test('a hash that disagrees with the reassembled payload is rejected', () {
    final fixture = _fixture('sample');
    final frames = (fixture['frames'] as List).cast<String>();
    final set = QrFrameSet();
    for (final f in frames) {
      expect(set.add(f), QrAddResult.added);
    }
    set.hash = '0000000000000000';
    expect(() => decodeQrFrames(set), throwsFormatException);
  });

  test('refuses a payload that is not a JSON object', () {
    // The frames are well formed and the hash matches; only the shape is wrong.
    final set = QrFrameSet();
    for (final f in encodeQrFrames(<Object?>[1, 2, 3])) {
      expect(set.add(f), QrAddResult.added);
    }
    expect(() => decodeQrFrames(set), throwsFormatException);
  });

  test('refuses more reassembled text than the hub could ever produce', () {
    // Every character is valid base45 and the CRC is right, so only the length
    // bound can reject this — before base45Decode allocates anything.
    final chunk = '0' * (kMaxQrFrames * kQrChunkChars + 1);
    final set = QrFrameSet();
    expect(
      set.add('FRL2:0123456789ABCDEF:0:1:${crc32Hex(utf8.encode(chunk))}:$chunk'),
      QrAddResult.added,
    );
    expect(() => decodeQrFrames(set), throwsFormatException);
  });

  test('refuses a gzip stream that claims to expand past the payload cap', () {
    // A gzip bomb announces its size in the ISIZE trailer, which is checked
    // before the stream is handed to the decoder.
    final gzip = Uint8List.fromList(
      const GZipEncoder().encodeBytes(utf8.encode('{"version":2}'), level: 9),
    );
    final claimed = kMaxQrPayloadBytes + 1;
    for (var b = 0; b < 4; b += 1) {
      gzip[gzip.length - 4 + b] = (claimed >> (8 * b)) & 0xff;
    }
    final chunk = base45Encode(gzip);
    final set = QrFrameSet();
    expect(
      set.add('FRL2:0123456789ABCDEF:0:1:${crc32Hex(utf8.encode(chunk))}:$chunk'),
      QrAddResult.added,
    );
    // The decoder would also notice the lie, but only after inflating the
    // stream; the ISIZE check is what keeps that allocation from happening.
    expect(
      () => decodeQrFrames(set),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('claims ${kMaxQrPayloadBytes + 1} bytes'),
        ),
      ),
    );
  });

  test('refuses to encode a payload that needs more frames than allowed', () {
    expect(
      () => encodeQrFrames(<String, Object?>{'a': 'x' * 5000},
          chunkChars: 10, maxFrames: 4),
      throwsStateError,
    );
  });
}
