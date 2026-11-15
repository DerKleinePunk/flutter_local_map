import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/src/services/map_camera_bounds.dart';
import 'package:local_map/src/services/mbtiles_sources.dart';
import 'package:mbtiles/mbtiles.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Kacheln, die nicht aus unserem eigenen Bau stammen.
///
/// planetiler (und damit z. B. der Yapaia-Kartenserver) schreibt andere
/// Metadaten als unser tilemaker-Bau: `version` ist eine Versionsnummer
/// (`3.16.0` statt `3.0`), und die Kacheln enden bei z14 statt z17. Beides
/// hat die Karte bis 0.11.1 nicht vertragen - gefunden mit einem
/// Liechtenstein-Paket aus planetiler 0.10.2 (15.11.2026).

/// Metadaten genau so, wie planetiler 0.10.2 sie fuer Liechtenstein schreibt
/// (ohne `json`, das hier nichts beitraegt).
const _planetilerMetadata = {
  'name': 'OpenMapTiles',
  'version': '3.16.0',
  'type': 'baselayer',
  'format': 'pbf',
  'bounds': '9.47108,47.04774,9.63622,47.27128',
  'center': '9.55365,47.15951,11',
  'minzoom': '0',
  'maxzoom': '14',
  'compression': 'gzip',
  'planetiler:version': '0.10.2',
};

String _writeMbtiles(Directory dir, Map<String, String> metadata) {
  final path = '${dir.path}/fremd.mbtiles';
  final db = sqlite.sqlite3.open(path);
  db.execute('CREATE TABLE metadata (name TEXT, value TEXT)');
  db.execute(
    'CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, '
    'tile_row INTEGER, tile_data BLOB)',
  );
  final insert = db.prepare('INSERT INTO metadata VALUES (?, ?)');
  metadata.forEach((k, v) => insert.execute([k, v]));
  insert.close();
  // Eine gzip-gepackte (leere) Vektorkachel bei Vaduz.
  db.execute('INSERT INTO tiles VALUES (?, ?, ?, ?)', [
    14,
    8625,
    (1 << 14) - 1 - 5762,
    gzip.encode(const <int>[1, 2, 3]),
  ]);
  db.close();
  return path;
}

void main() {
  group('effectiveMaxZoom', () {
    test('fremde Kacheln bis z14: Kamera darf bis overzoomUntil', () {
      expect(
        effectiveMaxZoom(fromMetadata: 14, configured: 14, overzoomUntil: 17),
        17,
      );
    });

    test('eigene Kacheln bis z17 bleiben bei 17', () {
      expect(
        effectiveMaxZoom(fromMetadata: 17, configured: 14, overzoomUntil: 17),
        17,
      );
    });

    test('overzoomUntil 0 laesst den Wert aus den Metadaten stehen', () {
      expect(
        effectiveMaxZoom(fromMetadata: 14, configured: 18, overzoomUntil: 0),
        14,
      );
    });

    test('ohne Metadaten gilt die Konfiguration', () {
      expect(
        effectiveMaxZoom(fromMetadata: null, configured: 15, overzoomUntil: 17),
        15,
      );
    });

    test('nativeMaxZoom ist die letzte Stufe mit echten Kacheln', () {
      expect(nativeMaxZoom(fromMetadata: 14, configured: 18), 14);
      expect(nativeMaxZoom(fromMetadata: null, configured: 15.5), 15);
    });
  });

  group('MBTiles aus planetiler oeffnen', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('fremde_kacheln_');
      path = _writeMbtiles(dir, _planetilerMetadata);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('Gegenprobe: mbtiles allein scheitert an version = 3.16.0', () {
      // So hat local_map bis 0.11.1 geoeffnet. Wird das hier einmal gruen,
      // hat mbtiles den Fehler behoben - die Umgehung schadet dann nicht.
      expect(() => MbTiles(path: path), throwsFormatException);
    });

    test('Vektorquelle oeffnet ohne getMetadata()', () async {
      final mbtiles = openVectorMbTiles(path);
      addTearDown(mbtiles.close);

      final provider = vectorTileProvider(mbtiles, minZoom: 0, maxZoom: 14);

      expect(provider.minimumZoom, 0);
      // Letzte echte Stufe; darueber vergroessert vector_map_tiles.
      expect(provider.maximumZoom, 14);
      final tile = await provider.provide(TileIdentity(14, 8625, 5762));
      expect(tile, isNotEmpty);
    });

    test('Rasterquelle oeffnet ohne getMetadata()', () {
      final mbtiles = openRasterMbTiles(path);
      addTearDown(mbtiles.close);
      expect(
        mbtiles.getTile(z: 14, x: 8625, y: (1 << 14) - 1 - 5762),
        isNotNull,
      );
    });
  });
}
