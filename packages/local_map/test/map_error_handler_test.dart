import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';

void main() {
  group('MapErrorHandler', () {
    test('classifies asset missing errors', () {
      final error = Exception('asset not found: assets/maps/style.json');
      final classified = MapErrorHandler.classify(
        error,
        null,
        context: 'test',
      );

      expect(
        classified.category,
        equals(MapErrorCategory.assetMissing),
      );
      expect(
        classified.userMessage,
        contains('Asset nicht gefunden'),
      );
    });

    test('classifies json decode errors', () {
      final error = Exception('Invalid JSON: expected }');
      final classified = MapErrorHandler.classify(
        error,
        null,
        context: 'style.json',
      );

      expect(
        classified.category,
        equals(MapErrorCategory.jsonInvalid),
      );
      expect(
        classified.userMessage,
        contains('ungültig'),
      );
    });

    test('classifies unsupported format correctly', () {
      final error = MapErrorHandler.classifyUnsupportedFormat(
        'tiff',
        mbtilesPath: '/path/to/map.mbtiles',
      );

      expect(
        error.category,
        equals(MapErrorCategory.mbtilesFormatUnsupported),
      );
      expect(
        error.userMessage,
        contains('tiff'),
      );
    });

    test('MbTilesException stores category information', () {
      final exc = MbTilesException(
        'Test error',
        category: MapErrorCategory.styleMissingSource,
      );

      expect(exc.category, equals(MapErrorCategory.styleMissingSource));
      expect(exc.message, equals('Test error'));
    });
  });
}
