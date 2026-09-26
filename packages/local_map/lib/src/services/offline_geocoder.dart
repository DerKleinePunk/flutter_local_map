import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:math' as math;

import '../api/place_search.dart';
import '../api/reverse_geocoder.dart';
import 'map_error_handler.dart';

class GeocoderResult {
  final String name;
  final LatLng location;
  final int zoom;
  final String type; // 'place', 'poi', 'mountain_peak'
  final String? detail;

  /// Der Ort, zu dem der Treffer gehört - bei Straßen, POIs und Gewässern der
  /// Ort, in dem sie liegen, bei einem Ort der größere Ort in der Nähe
  /// ("Neustadt" bei "Marburg"). Erst damit lassen sich die tausend
  /// Hauptstraßen auseinanderhalten. `null` bei Namensdatenbanken von vor
  /// September 2026 und wo kein Ort in der Nähe ist.
  final String? area;

  GeocoderResult({
    required this.name,
    required this.location,
    required this.zoom,
    required this.type,
    this.detail,
    this.area,
  });

  /// Rang in der Trefferliste, kleiner = weiter oben: Orte, POIs, Berge,
  /// Gewässer, Straßen. Bushaltestellen stehen hinter den Straßen - sie
  /// heißen oft wie die Straße, und wer "Hauptstraße" tippt, meint die.
  /// Benannte Stellen ohne Einwohner (`locality` - Flurnamen, oft auch nur
  /// ein Straßenname als Punkt - Plätze, Felder) zählen wie Straßen; sonst
  /// schlägt eine "Bahnhofstrasse" im Simmental die in Zürich.
  int get searchRank => switch (type) {
    'place' when _unpopulatedPlaces.contains(detail) => 4,
    'place' => 0,
    'poi' when detail == 'bus' => 5,
    'poi' => 1,
    'mountain_peak' => 2,
    'water_name' => 3,
    'transportation_name' => 4,
    _ => 99,
  };

  static const Set<String> _unpopulatedPlaces = {
    'locality',
    'square',
    'field',
    'plot',
    'allotments',
    'city_block',
  };

  @override
  String toString() => area == null ? '$name ($type)' : '$name, $area ($type)';
}

/// [PlaceSearch] und [ReverseGeocoder] über eine lokale Namensdatenbank
/// (SQLite mit FTS5).
///
/// Die Rückwärtssuche braucht die Tabellen `reverse_*`, die
/// `extract_names_to_sqlite.py` seit September 2026 mit anlegt. Mit einer
/// älteren Datenbank liefert [nameAt] immer `null`, die Suche geht weiter.
///
/// Jede Instanz hält ihre eigene Verbindung. Wer sie anlegt, schließt sie
/// auch wieder mit [close].
class OfflineGeocoder implements PlaceSearch, ReverseGeocoder {
  Database? _database;
  String? _currentNamesDb;
  bool _hasReverseTables = false;
  bool _hasArea = false;

  /// Ob die Suchtabelle den Typ und ein Rasterfeld im Index hat (seit
  /// September 2026). Nur dann gibt es die Umkreissuche, und der Typfilter
  /// steht im MATCH-Ausdruck.
  bool _hasGrid = false;

  /// Kantenlänge der Rasterfelder in Grad, wie SEARCH_GRID_DEG in
  /// scripts/extract_names_to_sqlite.py.
  static const double _gridDegrees = 0.5;

  /// Treffer aus diesem Umkreis kommen mit `near` vor dem Rest des Landes.
  static const double _nearRadiusMeters = 50000;

  /// Erst ab so vielen Zeichen wird im Umkreis gesucht. Ein einzelner
  /// Buchstabe trifft bei DACH Hunderttausende Namen, die alle nach
  /// Entfernung sortiert werden müssten - das dauert auf dem Pi Sekunden.
  static const int _nearMinChars = 3;

  static const List<String> _typePriority = [
    'place',
    'poi',
    'mountain_peak',
    'water_name',
    'transportation_name',
  ];

  /// Wie weit eine Straße höchstens weg sein darf, um als "die Straße, auf
  /// der man ist" zu gelten. Die Punkte liegen alle 100 m auf der Linie,
  /// also bis 50 m daneben, dazu die GPS-Ungenauigkeit.
  static const double _streetRadiusMeters = 80;

  /// Straßenklassen, die keine Straßen sind, auf denen man fährt.
  static const Set<String> _notStreets = {
    'rail',
    'transit',
    'ferry',
    'aerialway',
    'raceway',
    'busway',
  };

  /// Aufschlag in Metern für Wege, die nur gewinnen sollen, wenn keine
  /// richtige Straße in der Nähe ist - Parkplatzgassen, Feld- und Fußwege.
  static const Map<String, double> _streetPenaltyMeters = {
    'service': 25,
    'track': 40,
    'path': 40,
  };

  /// Gewicht und Reichweite in Metern je Ortsart. Die Entfernung wird durch
  /// das Gewicht geteilt: eine Stadt in 1,7 km schlägt ihr eigenes Viertel
  /// in 1 km, ein Dorf in 800 m den Weiler am Ortsrand in 500 m.
  static const Map<String, (double, double)> _localityClasses = {
    'city': (4, 15000),
    'town': (2.5, 8000),
    'municipality': (2, 6000),
    'village': (1.5, 4000),
    'hamlet': (0.7, 1500),
    'isolated_dwelling': (0.4, 500),
    'farm': (0.4, 500),
  };

  /// Ortsteile, die zusätzlich zum Ort genannt werden, wenn sie so nah sind.
  static const Map<String, double> _districtRadiusMeters = {
    'suburb': 1500,
    'quarter': 800,
    'neighbourhood': 500,
    'borough': 2000,
  };

  OfflineGeocoder();

  /// Namen, die genau der Eingabe entsprechen, kommen vor denen, die nur so
  /// anfangen ("Fulda" vor "Fulda-Galerie"), jeweils in der Rangfolge der
  /// Typen ([GeocoderResult.searchRank]). Mit [near] wird danach nach
  /// Entfernung sortiert.
  @override
  Future<List<GeocoderResult>> searchPlaces(
    String query, {
    int limit = 15,
    LatLng? near,
  }) async {
    // FTS liefert Treffer ohne Ortsbezug und ohne Rangfolge. Mehr holen,
    // damit der genaue und die nahen Treffer ueberhaupt dabei sind - mit
    // [near] zuerst die aus der Umgebung, sonst fiele von tausend
    // Hauptstraßen eine beliebige Auswahl heraus.
    final trimmed = query.trim();
    final candidates = <GeocoderResult>[];
    if (near != null && _hasGrid && trimmed.length >= _nearMinChars) {
      candidates.addAll(await _searchNear(trimmed, near, limit: limit * 10));
    }
    final seen = {for (final r in candidates) _identity(r)};
    for (final r in await searchPrioritized(trimmed, limit: limit * 10)) {
      if (seen.add(_identity(r))) candidates.add(r);
    }
    final wanted = trimmed.toLowerCase();
    bool isExact(GeocoderResult r) {
      final name = r.name.toLowerCase();
      return name == wanted ||
          (r.area != null && '$name ${r.area!.toLowerCase()}' == wanted);
    }

    const distance = Distance();
    // Ein POI, der genau wie eine Straße im selben Ort heißt - Haltestelle,
    // Infotafel, Parkplatz "Hauptstraße" -, kommt hinter die Straßen. Nur im
    // selben Ort: eine Straße "Hauptbahnhof" in Mainz soll den Frankfurter
    // Hauptbahnhof nicht verdrängen.
    String streetKey(GeocoderResult r) => '${r.name.toLowerCase()}|${r.area}';
    final streets = {
      for (final r in candidates)
        if (r.type == 'transportation_name') streetKey(r),
    };
    int rankOf(GeocoderResult r) =>
        r.type == 'poi' && streets.contains(streetKey(r)) ? 5 : r.searchRank;
    // Erst alle genauen Treffer, dann die, die nur so anfangen oder das Wort
    // enthalten - sonst schlägt "Spielplatz Hauptstraße" (POI) die Straße.
    // Innerhalb davon nach Rang, dann nach Nähe.
    final ordered = <GeocoderResult>[];
    for (final exact in [true, false]) {
      final byRank = <int, List<GeocoderResult>>{};
      for (final r in candidates) {
        if (isExact(r) == exact) {
          byRank.putIfAbsent(rankOf(r), () => []).add(r);
        }
      }
      for (final rank in byRank.keys.toList()..sort()) {
        final group = byRank[rank]!;
        if (near != null) {
          group.sort(
            (a, b) => distance(
              near,
              a.location,
            ).compareTo(distance(near, b.location)),
          );
        }
        ordered.addAll(group);
      }
    }
    return ordered.take(limit).toList();
  }

  /// Initialize geocoder with a names database
  /// Returns true if database was loaded successfully
  Future<bool> initialize(String namesDatabasePath) async {
    try {
      if (_database != null && _currentNamesDb == namesDatabasePath) {
        return true; // Already initialized with this database
      }

      final file = File(namesDatabasePath);
      if (!file.existsSync()) {
        MapErrorHandler.logDebug(
          'Database not found: $namesDatabasePath',
          context: 'geocoder',
        );
        return false;
      }

      // Close previous database if open
      await _database?.close();

      MapErrorHandler.logDebug(
        'Attempting to open database: $namesDatabasePath',
        context: 'geocoder',
      );
      _database = await openDatabase(namesDatabasePath, readOnly: true);
      _currentNamesDb = namesDatabasePath;

      // Verify tables exist
      final tables = await _database!.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('names', 'names_meta')",
      );

      if (tables.isEmpty) {
        MapErrorHandler.logDebug(
          'Required tables not found in database',
          context: 'geocoder',
        );
        await _database?.close();
        _database = null;
        _currentNamesDb = null;
        return false;
      }

      final reverse = await _database!.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' "
        "AND name IN ('reverse_places_pos', 'reverse_streets_pos')",
      );
      _hasReverseTables = reverse.length == 2;
      final columns = await _database!.rawQuery(
        'PRAGMA table_info(names_meta)',
      );
      // Mit dem Ortsbezug kam auch rowid = id, auf dem die Umkreissuche
      // aufbaut.
      _hasArea = columns.any((c) => c['name'] == 'context');
      final ftsColumns = await _database!.rawQuery('PRAGMA table_info(names)');
      _hasGrid = ftsColumns.any((c) => c['name'] == 'cell');
      if (!_hasReverseTables) {
        MapErrorHandler.logInfo(
          'Namensdatenbank ohne reverse_*-Tabellen, keine Anzeige des '
          'Standorts - mit extract_names_to_sqlite.py neu erzeugen',
          context: 'geocoder',
        );
      }

      MapErrorHandler.logDebug(
        'Initialized with $namesDatabasePath',
        context: 'geocoder',
      );
      return true;
    } catch (e) {
      MapErrorHandler.logError('Error initializing: $e', context: 'geocoder');
      return false;
    }
  }

  @override
  Future<LocationName?> nameAt(LatLng position) async {
    final db = _database;
    if (db == null || !_hasReverseTables) return null;
    try {
      final street = await _nearestStreet(db, position);
      final places = await _nearbyPlaces(db, position);
      String? locality;
      double bestScore = double.infinity;
      String? district;
      double bestDistrict = double.infinity;
      for (final (name, detail, meters) in places) {
        final locClass = _localityClasses[detail];
        if (locClass != null) {
          final (weight, radius) = locClass;
          final score = meters / weight;
          if (meters <= radius && score < bestScore) {
            bestScore = score;
            locality = name;
          }
        }
        final districtRadius = _districtRadiusMeters[detail];
        if (districtRadius != null &&
            meters <= districtRadius &&
            meters < bestDistrict) {
          bestDistrict = meters;
          district = name;
        }
      }
      if (district == locality) district = null;
      final result = LocationName(
        street: street,
        locality: locality,
        district: district,
      );
      return result.isEmpty ? null : result;
    } catch (e) {
      MapErrorHandler.logError('Reverse lookup error: $e', context: 'geocoder');
      return null;
    }
  }

  Future<String?> _nearestStreet(Database db, LatLng position) async {
    final rows = await _pointsAround(
      db,
      'reverse_streets',
      position,
      _streetRadiusMeters + 50,
    );
    String? best;
    double bestScore = double.infinity;
    for (final (name, detail, meters) in rows) {
      if (meters > _streetRadiusMeters || _notStreets.contains(detail)) {
        continue;
      }
      final score = meters + (_streetPenaltyMeters[detail] ?? 0);
      if (score < bestScore) {
        bestScore = score;
        best = name;
      }
    }
    return best;
  }

  Future<List<(String, String?, double)>> _nearbyPlaces(
    Database db,
    LatLng position,
  ) => _pointsAround(db, 'reverse_places', position, 15000);

  /// Alle Punkte aus [table] in einem Quadrat von 2 x [radiusMeters] um
  /// [position], mit Name, Art und Entfernung in Metern.
  Future<List<(String, String?, double)>> _pointsAround(
    Database db,
    String table,
    LatLng position,
    double radiusMeters,
  ) async {
    const metersPerDegree = 111195.0;
    final cosLat = math.cos(position.latitude * math.pi / 180);
    final dLat = radiusMeters / metersPerDegree;
    final dLng = radiusMeters / (metersPerDegree * math.max(cosLat, 0.01));
    int e5(double degrees) => (degrees * 1e5).round();
    final rows = await db.rawQuery(
      '''
      SELECT n.name, n.detail, p.lat_e5, p.lng_e5
      FROM $table p JOIN reverse_names n ON n.id = p.name_id
      WHERE p.lat_e5 BETWEEN ? AND ? AND p.lng_e5 BETWEEN ? AND ?
      ''',
      [
        e5(position.latitude - dLat),
        e5(position.latitude + dLat),
        e5(position.longitude - dLng),
        e5(position.longitude + dLng),
      ],
    );
    return [
      for (final row in rows)
        (
          row['name'] as String,
          row['detail'] as String?,
          // Auf die kurzen Strecken hier genügt die Rechteckprojektion.
          metersPerDegree *
              math.sqrt(
                math.pow((row['lat_e5'] as int) / 1e5 - position.latitude, 2) +
                    math.pow(
                      ((row['lng_e5'] as int) / 1e5 - position.longitude) *
                          cosLat,
                      2,
                    ),
              ),
        ),
    ];
  }

  /// Search for places by name using FTS5
  Future<List<GeocoderResult>> search(String query, {int limit = 20}) =>
      _match(query, limit: limit);

  /// Get names by type (place, poi, mountain_peak)
  Future<List<GeocoderResult>> searchByType(
    String query, {
    required String type,
    int limit = 20,
  }) => _match(query, type: type, limit: limit);

  /// Treffer im Umkreis von [near], je Typ nach Entfernung sortiert.
  Future<List<GeocoderResult>> _searchNear(
    String query,
    LatLng near, {
    required int limit,
  }) async {
    final results = <GeocoderResult>[];
    for (final type in _typePriority) {
      results.addAll(await _match(query, type: type, limit: limit, near: near));
    }
    return results;
  }

  /// Der FTS5-Ausdruck zu einer Eingabe: jedes Wort als Präfix, irgendwo in
  /// Name oder Ort, aber mindestens eines im Namen. So findet "Hauptstraße
  /// Alsfeld" die Hauptstraße in Alsfeld, "Alsfeld" allein aber nicht jede
  /// Straße dort. Die Wörter stehen in Anführungszeichen, damit Bindestriche
  /// und Klammern keine FTS-Syntax sind.
  String? _matchExpression(String query) {
    final words = query
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => '"${w.replaceAll('"', '""')}"*')
        .toList();
    if (words.isEmpty) return null;
    if (words.length == 1 || !_hasArea) return 'name : (${words.join(' ')})';
    return '(${words.join(' ')}) AND (${words.map((w) => 'name : $w').join(' OR ')})';
  }

  Future<List<GeocoderResult>> _match(
    String query, {
    String? type,
    required int limit,
    LatLng? near,
  }) async {
    final db = _database;
    final expression = _matchExpression(query);
    if (db == null || expression == null) return [];

    // Gemessen auf dem Pi 4 mit DACH (5,3 Mio. Namen): Typ und Umkreis
    // gehören in den MATCH-Ausdruck, dann erledigt sie der Index. Als
    // "type = ?" oder als Lat/Lng-Filter hinter der Textsuche prüft SQLite
    // jeden Treffer einzeln - "Hau" in der Nähe 2,2 s statt 134 ms.
    final match = StringBuffer(expression);
    final where = StringBuffer();
    final args = <Object?>[];
    if (type != null) {
      if (_hasGrid) {
        match.write(' AND type : "${type.replaceAll('"', '""')}"');
      } else {
        where.write(' AND type = ?');
        args.add(type);
      }
    }
    var order = '';
    if (near != null && _hasGrid) {
      const metersPerDegree = 111195.0;
      final cosLat = math.cos(near.latitude * math.pi / 180);
      final dLat = _nearRadiusMeters / metersPerDegree;
      final dLng = dLat / math.max(cosLat, 0.01);
      match.write(
        ' AND cell : (${_cellsAround(near, dLat, dLng).join(' OR ')})',
      );
      where.write(' AND lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?');
      args.addAll([
        near.latitude - dLat,
        near.latitude + dLat,
        near.longitude - dLng,
        near.longitude + dLng,
      ]);
      order =
          ' ORDER BY (lat - ?) * (lat - ?) + '
          '(lng - ?) * (lng - ?) * ${cosLat * cosLat}';
      args.addAll([
        near.latitude,
        near.latitude,
        near.longitude,
        near.longitude,
      ]);
    }
    args.add(limit);
    final area = _hasArea ? 'context' : 'NULL AS context';

    try {
      final results = await db.rawQuery(
        'SELECT id, name, lat, lng, zoom, type, detail, $area FROM names '
        'WHERE names MATCH ?$where$order LIMIT ?',
        [match.toString(), ...args],
      );
      return results
          .map(
            (row) => GeocoderResult(
              name: row['name'] as String,
              location: LatLng(
                (row['lat'] as num).toDouble(),
                (row['lng'] as num).toDouble(),
              ),
              zoom: row['zoom'] as int,
              type: row['type'] as String,
              detail: row['detail'] as String?,
              area: row['context'] as String?,
            ),
          )
          .toList();
    } catch (e) {
      MapErrorHandler.logError('Search error: $e', context: 'geocoder');
      return [];
    }
  }

  /// Die Rasterfelder, die das Rechteck um [center] berühren, als Wörter
  /// des Suchindex ("g281x378").
  static List<String> _cellsAround(LatLng center, double dLat, double dLng) {
    int row(double lat) => ((lat + 90) / _gridDegrees).floor();
    int col(double lng) => ((lng + 180) / _gridDegrees).floor();
    return [
      for (
        var r = row(center.latitude - dLat);
        r <= row(center.latitude + dLat);
        r++
      )
        for (
          var c = col(center.longitude - dLng);
          c <= col(center.longitude + dLng);
          c++
        )
          'g${r}x$c',
    ];
  }

  static (String, String, double, double) _identity(GeocoderResult r) =>
      (r.name, r.type, r.location.latitude, r.location.longitude);

  /// Search with type prioritization: place > poi > mountain_peak > water_name > transportation_name
  /// Returns results ordered by type priority, then by name
  Future<List<GeocoderResult>> searchPrioritized(
    String query, {
    int limit = 20,
  }) async {
    if (_database == null) {
      return [];
    }

    try {
      final allResults = <GeocoderResult>[];

      for (final type in _typePriority) {
        if (allResults.length >= limit) break;
        final typeResults = await searchByType(
          query,
          type: type,
          limit: limit - allResults.length,
        );
        allResults.addAll(typeResults);
      }

      return allResults;
    } catch (e) {
      MapErrorHandler.logError(
        'Prioritized search error: $e',
        context: 'geocoder',
      );
      return [];
    }
  }

  /// Copy names database from assets to app documents
  /// Useful for development/testing
  Future<String?> copyDatabaseFromAssets(String sourceAssetPath) async {
    try {
      final documentDir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(documentDir.path, p.basename(sourceAssetPath));
      final dbFile = File(dbPath);

      // Only copy if not already present
      if (!dbFile.existsSync()) {
        final data = await rootBundle.load(sourceAssetPath);
        await dbFile.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        MapErrorHandler.logDebug(
          'Copied database from assets to $dbPath',
          context: 'geocoder',
        );
      }

      return dbPath;
    } catch (e) {
      MapErrorHandler.logError(
        'Error copying database: $e',
        context: 'geocoder',
      );
      return null;
    }
  }

  /// Close the database
  Future<void> close() async {
    await _database?.close();
    _database = null;
    _currentNamesDb = null;
    _hasReverseTables = false;
    _hasArea = false;
    _hasGrid = false;
  }

  /// Check if database is initialized
  bool get isInitialized => _database != null;
}
