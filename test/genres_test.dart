import 'package:blimp/services/genres.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps micro-genres onto broad genres by their head word', () {
    const expected = {
      'Conscious Hip Hop': 'Hip-Hop',
      'Rap/Hip Hop': 'Hip-Hop',
      'Malay Rap': 'Hip-Hop',
      'Drift Phonk': 'Hip-Hop',
      'Phonk Brasileiro': 'Hip-Hop',
      'Alternative Rock': 'Rock',
      'Uk Post-Punk Revival': 'Rock',
      'Neo-Rockabilly': 'Rock',
      'Dance Pop': 'Pop',
      'Malaysian Pop': 'Pop',
      'Europop': 'Pop',
      'K-Pop Girl Group': 'K-Pop',
      'Canadian Contemporary R&B': 'R&B & Soul',
      'Neo Soul': 'R&B & Soul',
      'Brostep': 'Dance & Electronic',
      'Bass Trap': 'Dance & Electronic',
      'Electro House': 'Dance & Electronic',
      'Alternative Dance': 'Dance & Electronic',
      'Dancefloor Dnb': 'Dance & Electronic',
      'Super Eurobeat': 'Dance & Electronic',
      'Krushfunk': 'Dance & Electronic',
      'Japanese Vgm': 'Video Game Music',
      'Gaming Edm': 'Video Game Music',
      'Indie Game Soundtrack': 'Video Game Music',
      'Anime Score': 'Soundtracks & Musicals',
      'Bristol Indie': 'Indie & Alternative',
      'Austindie': 'Indie & Alternative',
      'French Shoegaze': 'Indie & Alternative',
      'Ectofolk': 'Folk & Acoustic',
      'Irish Singer-Songwriter': 'Folk & Acoustic',
      'Arkansas Country': 'Country & Americana',
      'New Orleans Jazz': 'Jazz',
      'Melodic Metalcore': 'Metal',
      'Bossa Nova': 'Latin',
      'Compositional Ambient': 'Chill',
    };
    for (final MapEntry(key: tag, value: genre) in expected.entries) {
      expect(normalizeGenre(tag), genre, reason: tag);
    }
  });

  test('keeps unrecognized tags and handles missing ones', () {
    expect(normalizeGenre('Wrestling'), 'Wrestling');
    expect(normalizeGenre('Lagu Sabahan'), 'Lagu Sabahan');
    expect(normalizeGenre(null), isNull);
    expect(normalizeGenre('Music'), isNull);
    expect(normalizeGenre('Indietronica'), 'Dance & Electronic');
  });
}
