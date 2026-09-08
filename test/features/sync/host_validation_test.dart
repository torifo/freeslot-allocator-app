import 'package:flutter_test/flutter_test.dart';
import 'package:frelocator/features/sync/presentation/sync_settings_screen.dart';

void main() {
  group('hostValidationError', () {
    // What the user is holding, and whether the dialog may dial it.
    const cases = <String, bool>{
      '192.168.1.9': true,
      // A paste from a terminal carries the space; trimming it is the obvious
      // fix, so the dialog does it instead of scolding (I-3).
      '192.168.1.9 ': true,
      ' 192.168.1.9': true,
      // Digits and dots that are not an address: the hostname grammar used to
      // wave both of these through (I-4).
      '999.999.999.999': false,
      '192.168.1': false,
      '256.0.0.1': false,
      'localhost': true,
      'my-hub.local': true,
      '::1': true,
      'fe80::1': true,
      '[::1]': true,
      '192.168 1.9': false,
      '': false,
      '   ': false,
      'my hub.local': false,
      '192.168.1.9/api': false,
    };

    cases.forEach((input, isValid) {
      test('${isValid ? 'accepts' : 'refuses'} "$input"', () {
        expect(
          hostValidationError(input),
          isValid ? isNull : isNotNull,
          reason: input,
        );
      });
    });

    test('names what is missing rather than what is wrong', () {
      expect(hostValidationError(''), 'ホストを入力してください');
      expect(hostValidationError('999.999.999.999'), contains('IP アドレス'));
    });
  });
}
