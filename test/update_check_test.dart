import 'package:blimp/services/update_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a higher number in any place is newer', () {
    expect(isNewerVersion('1.7.1', '1.7.0'), isTrue);
    expect(isNewerVersion('1.8.0', '1.7.9'), isTrue);
    expect(isNewerVersion('2.0.0', '1.99.99'), isTrue);
  });

  test('numbers are compared as numbers, not text', () {
    expect(isNewerVersion('1.10.0', '1.9.0'), isTrue);
    expect(isNewerVersion('1.9.0', '1.10.0'), isFalse);
  });

  test('the same or an older version is not newer', () {
    expect(isNewerVersion('1.7.0', '1.7.0'), isFalse);
    expect(isNewerVersion('1.6.5', '1.7.0'), isFalse);
  });

  test('a missing number counts as 0, and build numbers are ignored', () {
    expect(isNewerVersion('1.8', '1.7.9'), isTrue);
    expect(isNewerVersion('1.7', '1.7.0'), isFalse);
    expect(isNewerVersion('1.7.0+12', '1.7.0'), isFalse);
  });
}
