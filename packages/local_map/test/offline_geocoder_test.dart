import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Legt eine kleine Namensdatenbank im Schema von
/// scripts/extract_names_to_sqlite.py an.
String _createNamesDb(Directory dir) {
  final path = '${dir.path}/test_names.db';
  final db = sqlite.sqlite3.open(path);
  db.execute('''
    CREATE VIRTUAL TABLE names USING fts5(
      id UNINDEXED, name, lat UNINDEXED, lng UNINDEXED, zoom UNINDEXED,
      type UNINDEXED, detail, source_field UNINDEXED)
  ''');
  db.execute(
    'CREATE TABLE names_meta (id INTEGER PRIMARY KEY, name TEXT NOT NULL)',
  );
  final insert = db.prepare(
    'INSERT INTO names (id, name, lat, lng, zoom, type, detail, source_field) '
    "VALUES (?, ?, ?, ?, ?, ?, ?, 'name')",
  );
  for (final row in [
    [1, 'Hauptstraße', 51.30, 9.50, 15, 'transportation_name', 'Kassel'],
    [2, 'Hauptstraße', 50.75, 9.27, 15, 'transportation_name', 'Alsfeld'],
    [3, 'Hauptstraße', 50.11, 8.68, 15, 'transportation_name', 'Frankfurt'],
    [4, 'Hauptbahnhof', 50.10, 8.66, 14, 'poi', 'Frankfurt'],
    [5, 'Fulda-Galerie', 50.74, 9.26, 14, 'place', 'suburb'],
    [6, 'Fulda', 50.55, 9.68, 12, 'place', 'town'],
  ]) {
    insert.execute(row);
  }
  insert.close();
  db.close();
  return path;
}

void main() {
  late Directory dir;
  late OfflineGeocoder geocoder;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('geocoder_test');
    geocoder = OfflineGeocoder();
    expect(await geocoder.initialize(_createNamesDb(dir)), isTrue);
  });

  tearDown(() async {
    await geocoder.close();
    await dir.delete(recursive: true);
  });

  test('ohne near: Typen in Rangfolge, POI vor Strasse', () async {
    final results = await geocoder.searchPlaces('Haupt');
    expect(results.first.type, 'poi');
    expect(results.where((r) => r.name == 'Hauptstraße'), hasLength(3));
  });

  test(
    'mit near: die naechste Hauptstrasse zuerst, Typrangfolge bleibt',
    () async {
      final results = await geocoder.searchPlaces(
        'Haupt',
        near: const LatLng(50.74, 9.25), // bei Alsfeld
      );

      expect(results.first.type, 'poi', reason: 'Typrangfolge bleibt');
      final streets = results
          .where((r) => r.type == 'transportation_name')
          .map((r) => r.detail)
          .toList();
      // Von Alsfeld: Kassel ~64 km, Frankfurt ~81 km.
      expect(streets, ['Alsfeld', 'Kassel', 'Frankfurt']);
    },
  );

  test(
    'genauer Name vor Praefix-Treffer, auch wenn dieser naeher ist',
    () async {
      // Bei Alsfeld, Fulda-Galerie liegt direkt daneben.
      final results = await geocoder.searchPlaces(
        'fulda',
        near: const LatLng(50.74, 9.25),
      );
      expect(results.map((r) => r.name), ['Fulda', 'Fulda-Galerie']);
    },
  );

  test('genauer Name zuerst auch ohne near', () async {
    final results = await geocoder.searchPlaces('Fulda ');
    expect(results.first.name, 'Fulda');
  });

  test('limit gilt auch mit near', () async {
    final results = await geocoder.searchPlaces(
      'Haupt',
      limit: 2,
      near: const LatLng(51.3, 9.5),
    );
    expect(results, hasLength(2));
  });

  test('zwei Instanzen stoeren sich nicht mehr', () async {
    final other = OfflineGeocoder();
    await other.close();
    expect(geocoder.isInitialized, isTrue);
  });

  test('ohne reverse-Tabellen keine Standortanzeige', () async {
    expect(await geocoder.nameAt(const LatLng(50.75, 9.27)), isNull);
  });

  group('nameAt', () {
    late Directory reverseDir;
    late OfflineGeocoder reverse;

    setUp(() async {
      reverseDir = await Directory.systemTemp.createTemp('reverse_test');
      reverse = OfflineGeocoder();
      expect(await reverse.initialize(_createReverseDb(reverseDir)), isTrue);
    });

    tearDown(() async {
      await reverse.close();
      await reverseDir.delete(recursive: true);
    });

    test(
      'Strasse, Stadt und Viertel - nicht die Bahn, nicht die Parkgasse',
      () async {
        final name = await reverse.nameAt(_hbf);
        expect(name?.street, 'Willy-Brandt-Platz');
        // Das Viertel liegt naeher, die Stadt gewinnt trotzdem den Ort.
        expect(name?.locality, 'Braunschweig');
        expect(name?.district, 'Bebelhof');
        expect(name?.label, 'Willy-Brandt-Platz, Braunschweig (Bebelhof)');
      },
    );

    test('Dorf schlaegt den naeheren Weiler', () async {
      final name = await reverse.nameAt(_bortfeld);
      expect(name?.locality, 'Bortfeld');
      expect(name?.street, isNull, reason: 'keine Strasse im Umkreis');
    });

    test('ohne Daten in der Naehe null', () async {
      expect(await reverse.nameAt(const LatLng(47.5, 12.0)), isNull);
    });
  });
}

const _hbf = LatLng(52.25300, 10.53960);
const _bortfeld = LatLng(52.30000, 10.40000);

/// [from] um [northM] Meter nach Norden und [eastM] nach Osten verschoben,
/// als Koordinaten in 1e-5 Grad wie in der Datenbank.
(int, int) _e5(LatLng from, double northM, double eastM) {
  const metersPerDegree = 111195.0;
  final lat = from.latitude + northM / metersPerDegree;
  final lng =
      from.longitude +
      eastM / (metersPerDegree * math.cos(from.latitude * math.pi / 180));
  return ((lat * 1e5).round(), (lng * 1e5).round());
}

/// Die reverse-Tabellen von scripts/extract_names_to_sqlite.py, gefüllt mit
/// dem, was die echte Braunschweig-Datenbank an diesen Stellen liefert.
String _createReverseDb(Directory dir) {
  final path = '${dir.path}/reverse_names.db';
  final db = sqlite.sqlite3.open(path);
  db.execute('''
    CREATE VIRTUAL TABLE names USING fts5(
      id UNINDEXED, name, lat UNINDEXED, lng UNINDEXED, zoom UNINDEXED,
      type UNINDEXED, detail, source_field UNINDEXED)
  ''');
  db.execute(
    'CREATE TABLE names_meta (id INTEGER PRIMARY KEY, name TEXT NOT NULL)',
  );
  db.execute(
    'CREATE TABLE reverse_names (id INTEGER PRIMARY KEY, name TEXT NOT NULL, '
    'type TEXT NOT NULL, detail TEXT)',
  );
  for (final table in ['reverse_places', 'reverse_streets']) {
    db.execute(
      'CREATE TABLE $table (name_id INTEGER NOT NULL, '
      'lat_e5 INTEGER NOT NULL, lng_e5 INTEGER NOT NULL)',
    );
  }
  var nextId = 1;
  void add(String kind, String name, String detail, (int, int) at) {
    final id = nextId++;
    db.execute(
      'INSERT INTO reverse_names (id, name, type, detail) VALUES (?, ?, ?, ?)',
      [id, name, kind, detail],
    );
    db.execute(
      'INSERT INTO reverse_${kind == 'street' ? 'streets' : 'places'} '
      '(name_id, lat_e5, lng_e5) VALUES (?, ?, ?)',
      [id, at.$1, at.$2],
    );
  }

  add('street', 'Willy-Brandt-Platz', 'primary', _e5(_hbf, 56, 0));
  add('street', 'Braunschweig–Wieren', 'rail', _e5(_hbf, -20, 0));
  add('street', 'Kiss-and-Go Haltebucht', 'service', _e5(_hbf, 0, 40));
  add('place', 'Bebelhof', 'quarter', _e5(_hbf, -700, 0));
  add('place', 'Braunschweig', 'city', _e5(_hbf, 1700, 0));
  add('place', 'Marina Bortfeld', 'hamlet', _e5(_bortfeld, 0, 502));
  add('place', 'Bortfeld', 'village', _e5(_bortfeld, 806, 0));
  db.execute(
    'CREATE INDEX reverse_places_pos ON reverse_places (lat_e5, lng_e5)',
  );
  db.execute(
    'CREATE INDEX reverse_streets_pos ON reverse_streets (lat_e5, lng_e5)',
  );
  db.close();
  return path;
}
