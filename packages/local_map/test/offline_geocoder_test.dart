import 'dart:io';

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
}
