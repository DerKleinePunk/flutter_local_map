import 'package:flutter_test/flutter_test.dart';
import 'package:map_local/map_screen.dart';

void main() {
  group('datex2FromEnvironment', () {
    test('ohne Adresse keine Quelle', () {
      expect(datex2FromEnvironment(const {}), isNull);
      expect(datex2FromEnvironment(const {'LOCAL_MAP_DATEX2_URL': ''}), isNull);
    });

    test('ungültige Adresse: keine Quelle', () {
      expect(
        datex2FromEnvironment(const {'LOCAL_MAP_DATEX2_URL': 'kein url'}),
        isNull,
      );
    });

    test('Adresse und Name', () {
      final s = datex2FromEnvironment(const {
        'LOCAL_MAP_DATEX2_URL': 'https://example.org/d2.xml',
        'LOCAL_MAP_DATEX2_NAME': 'MobiData BW',
      })!;
      expect(s.uri.toString(), 'https://example.org/d2.xml');
      expect(s.name, 'MobiData BW');
      s.close();
    });

    test('fehlendes Zertifikat hält die App nicht an', () {
      expect(
        datex2FromEnvironment(const {
          'LOCAL_MAP_DATEX2_URL': 'https://example.org/d2.xml',
          'LOCAL_MAP_DATEX2_P12': '/gibt/es/nicht.p12',
        }),
        isNull,
      );
    });
  });
}
