import 'package:blimp/services/desktop_equalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final flat = List.filled(DesktopEqualizer.frequencies.length, 0.0);

  test('flat gains need no filter, so the music passes through untouched', () {
    expect(DesktopEqualizer.filter(flat), isNull);
    expect(DesktopEqualizer.headroom(flat), 0);
  });

  test('only the bands that change get a filter', () {
    final gains = [...flat]
      ..[0] = 6
      ..[9] = -3.25;
    expect(
      DesktopEqualizer.filter(gains),
      'equalizer=f=31:t=o:w=1:g=6.0,equalizer=f=16000:t=o:w=1:g=-3.3',
    );
  });

  test('bands a song is too low in quality to hold are left out', () {
    final gains = [...flat]
      ..[0] = 6
      ..[9] = -3;
    const low = 'equalizer=f=31:t=o:w=1:g=6.0';
    expect(DesktopEqualizer.filter(gains, sampleRate: 22050), low);
    expect(DesktopEqualizer.filter(gains, sampleRate: 32000), low);
    expect(DesktopEqualizer.filter(gains, sampleRate: 44100), '$low,equalizer=f=16000:t=o:w=1:g=-3.0');
    expect(DesktopEqualizer.filter([...flat]..[9] = -3, sampleRate: 22050), isNull);
  });

  test('the volume comes down by the biggest boost', () {
    final gains = [...flat]
      ..[2] = 4
      ..[5] = 9
      ..[7] = -12;
    expect(DesktopEqualizer.headroom(gains), 9);
  });

  test('cuts alone need no turning down', () {
    expect(DesktopEqualizer.headroom([...flat]..[3] = -6), 0);
  });

  test('saved gains beyond the known bands are ignored', () {
    expect(DesktopEqualizer.filter([...flat, 5]), isNull);
  });
}
