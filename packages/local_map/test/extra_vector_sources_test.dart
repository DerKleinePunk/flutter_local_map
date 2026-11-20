import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';
import 'package:local_map/src/services/mbtiles_sources.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

/// Zusatzquellen in eigenen Dateien, etwa Hoehenlinien neben der Karte.
class _FakeProvider implements VectorTileProvider {
  _FakeProvider(this.name);
  final String name;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  String toString() => name;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Navigations-Style: Hoehenlinien als markierte Zusatzquelle', () async {
    final style =
        jsonDecode(
              await rootBundle.loadString(
                'packages/local_map/assets/maps/style_navigation.json',
              ),
            )
            as Map<String, dynamic>;
    expect(extraOnlySourceIds(style), {'contours'});

    final theme = vtr.ThemeReader(logger: const vtr.Logger.noop()).read(style);
    final ids = theme.layers.map((l) => l.id).toList();
    expect(
      ids,
      containsAll(['contour-minor', 'contour-major', 'contour-label']),
    );
    expect(theme.tileSources, containsAll(['openmaptiles', 'contours']));
  });

  group('resolveExtraSourcePath', () {
    test('relativer Name liegt neben der Hauptdatei', () {
      expect(
        resolveExtraSourcePath(
          '/data/offline_maps/germany.mbtiles',
          'vogelsberg_contours.mbtiles',
        ),
        '/data/offline_maps/vogelsberg_contours.mbtiles',
      );
    });

    test('absoluter Pfad bleibt, wie er ist', () {
      expect(
        resolveExtraSourcePath(
          '/data/offline_maps/germany.mbtiles',
          '/mnt/karten/contours.mbtiles',
        ),
        '/mnt/karten/contours.mbtiles',
      );
    });
  });

  group('assignVectorSourceProviders', () {
    final main = _FakeProvider('haupt');
    final contours = _FakeProvider('hoehen');

    test('ohne Zusatzquellen haengt alles an der Hauptkarte (wie bisher)', () {
      final map = assignVectorSourceProviders(
        sourceIds: {'openmaptiles', 'contours'},
        main: main,
      );
      expect(map['openmaptiles'], same(main));
      expect(map['contours'], same(main));
    });

    test('Zusatzquelle bekommt ihre eigene Datei', () {
      final map = assignVectorSourceProviders(
        sourceIds: {'openmaptiles', 'shortbread', 'contours'},
        main: main,
        extras: {'contours': contours},
      );
      expect(map['openmaptiles'], same(main));
      expect(map['shortbread'], same(main));
      expect(map['contours'], same(contours));
    });

    test('fehlende Zusatzdatei: Quelle bleibt leer statt Hauptkarte', () {
      final map = assignVectorSourceProviders(
        sourceIds: {'openmaptiles', 'contours'},
        main: main,
        configuredExtras: {'contours'},
      );
      expect(map['openmaptiles'], same(main));
      expect(map.containsKey('contours'), isFalse);
    });

    test('Zusatzquelle, die der Style nicht nennt, kommt nicht hinein', () {
      final map = assignVectorSourceProviders(
        sourceIds: {'openmaptiles'},
        main: main,
        extras: {'contours': contours},
      );
      expect(map.keys, ['openmaptiles']);
    });
  });

  group('extraOnlySourceIds', () {
    test('liest nur markierte Quellen', () {
      expect(
        extraOnlySourceIds({
          'sources': {
            'openmaptiles': {'type': 'vector'},
            'contours': {'type': 'vector', 'local_map:extra': true},
            'falsch': {'type': 'vector', 'local_map:extra': 'true'},
          },
        }),
        {'contours'},
      );
    });

    test('ohne sources leer', () {
      expect(extraOnlySourceIds({}), isEmpty);
    });
  });

  test('Quellenangabe Höhendaten nennt die Pflichtquellen', () {
    expect(MapConfig.elevationAttributionFull, contains('EU-DEM'));
    expect(MapConfig.elevationAttributionFull, contains('Copernicus'));
    expect(MapConfig.elevationAttributionFull, contains('(DGM) Österreich'));
    expect(MapConfig.elevationAttributionFull, contains('U.S. Geological'));
    expect(MapConfig.elevationAttributionShort, contains('EU-DEM'));
  });

  group('MapConfig.extraVectorSources', () {
    test('ist ohne Angabe leer', () {
      expect(MapConfig().extraVectorSources, isEmpty);
    });

    test('copyWith uebernimmt und ersetzt', () {
      final a = MapConfig(extraVectorSources: const {'contours': 'c.mbtiles'});
      expect(a.copyWith(minZoom: 5).extraVectorSources, {
        'contours': 'c.mbtiles',
      });
      expect(
        a.copyWith(extraVectorSources: const {}).extraVectorSources,
        isEmpty,
      );
    });
  });
}
