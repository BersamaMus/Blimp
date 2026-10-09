import 'package:blimp/services/search_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('drops apostrophes and periods, so they needn\'t be typed', () {
    expect(searchKey('Mr. Morale & The Big Steppers'), 'mr morale and the big steppers');
    expect(searchKey("Don't Stop Me Now"), 'dont stop me now');
    expect(searchKey('Don’t'), 'dont');
    expect(searchKey('K.O.I - Niskala Suaka'), 'koi niskala suaka');
  });

  test('ignores accents and case', () {
    expect(searchKey('Beyoncé'), 'beyonce');
    expect(searchKey('Sigur Rós'), 'sigur ros');
    expect(searchKey('Motörhead'), 'motorhead');
    expect(searchKey('Raffaella Carrà'), 'raffaella carra');
  });

  test('other punctuation separates words', () {
    expect(searchKey('AC/DC'), 'ac dc');
    expect(compactKey(searchKey('AC/DC')), 'acdc');
    expect(searchKey('Hood Gone Love It (feat. Kendrick Lamar)'), 'hood gone love it feat kendrick lamar');
    expect(searchKey('  !!! '), '');
  });

  test('keeps letters of other scripts', () {
    expect(searchKey('نيسكالا سواكا'), 'نيسكالا سواكا');
    expect(searchKey('東京事変'), '東京事変');
  });
}
