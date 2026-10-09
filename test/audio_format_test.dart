import 'package:blimp/services/media_library.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final song = Song(id: 1, title: 'x', uri: 'x', duration: const Duration(minutes: 4), size: 9600000);

  test('lossy files show bitrate', () {
    final format = AudioFormat.fromMap({'mime': 'audio/mpeg', 'bitrate': 320000, 'sampleRate': 44100, 'channels': 2}, song);
    expect(format.label, 'MP3 · 320 kbps · 44.1 kHz');
    expect(format.isHiRes, isFalse);
  });

  test('lossless files show bit depth and can be hi-res', () {
    final format = AudioFormat.fromMap({'mime': 'audio/flac', 'bitrate': 2400000, 'sampleRate': 96000, 'bitsPerSample': 24}, song);
    expect(format.label, 'FLAC · 24-bit · 96 kHz');
    expect(format.isHiRes, isTrue);
  });

  test('CD-quality lossless is not hi-res', () {
    final format = AudioFormat.fromMap({'mime': 'audio/raw', 'sampleRate': 44100, 'bitsPerSample': 16}, song);
    expect(format.label, 'WAV · 16-bit · 44.1 kHz');
    expect(format.isHiRes, isFalse);
  });

  test('missing bitrate is estimated from size and length', () {
    // 9.6 MB over 4 minutes is 320 kbps.
    final format = AudioFormat.fromMap({'mime': 'audio/mp4a-latm', 'sampleRate': 48000, 'channels': 1}, song);
    expect(format.label, 'AAC · 320 kbps · 48 kHz · Mono');
  });
}
