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

  GeocoderResult({
    required this.name,
    required this.location,
    required this.zoom,
    required this.type,
    this.detail,
  });

  @override
  String toString() => '$name ($type)';
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

  /// Die Rangfolge der Typen bleibt. Innerhalb eines Typs kommen Namen, die
  /// genau der Eingabe entsprechen, vor denen, die nur so anfangen ("Fulda"
  /// vor "Fulda-Galerie"). Mit [near] wird danach jeweils nach Entfernung
  /// sortiert.
  @override
  Future<List<GeocoderResult>> searchPlaces(
    String query, {
    int limit = 15,
    LatLng? near,
  }) async {
    // FTS liefert Treffer ohne Ortsbezug und ohne Rangfolge. Mehr holen,
    // damit der genaue und die nahen Treffer ueberhaupt dabei sind.
    final trimmed = query.trim();
    final candidates = await searchPrioritized(trimmed, limit: limit * 10);
    final wanted = trimmed.toLowerCase();
    const distance = Distance();
    final byType = <String, List<GeocoderResult>>{};
    for (final r in candidates) {
      byType.putIfAbsent(r.type, () => []).add(r);
    }
    final ordered = <GeocoderResult>[];
    for (final group in byType.values) {
      final exact = group.where((r) => r.name.toLowerCase() == wanted).toList();
      final rest = group.where((r) => r.name.toLowerCase() != wanted).toList();
      for (final part in [exact, rest]) {
        if (near != null) {
          part.sort(
            (a, b) => distance(
              near,
              a.location,
            ).compareTo(distance(near, b.location)),
          );
        }
        ordered.addAll(part);
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
  Future<List<GeocoderResult>> search(String query, {int limit = 20}) async {
    if (_database == null) {
      return [];
    }

    try {
      // Escape FTS5 query special characters
      final escapedQuery = query.replaceAll('"', '""');

      final results = await _database!.rawQuery(
        '''
        SELECT id, name, lat, lng, zoom, type, detail
        FROM names
        WHERE names MATCH ?
        LIMIT ?
        ''',
        ['$escapedQuery*', limit],
      );

      return results
          .map(
            (row) => GeocoderResult(
              name: row['name'] as String,
              location: LatLng(row['lat'] as double, row['lng'] as double),
              zoom: row['zoom'] as int,
              type: row['type'] as String,
              detail: row['detail'] as String?,
            ),
          )
          .toList();
    } catch (e) {
      MapErrorHandler.logError('Search error: $e', context: 'geocoder');
      return [];
    }
  }

  /// Get names by type (place, poi, mountain_peak)
  Future<List<GeocoderResult>> searchByType(
    String query, {
    required String type,
    int limit = 20,
  }) async {
    if (_database == null) {
      return [];
    }

    try {
      final escapedQuery = query.replaceAll('"', '""');

      final results = await _database!.rawQuery(
        '''
        SELECT id, name, lat, lng, zoom, type, detail
        FROM names
        WHERE names MATCH ? AND type = ?
        LIMIT ?
        ''',
        ['$escapedQuery*', type, limit],
      );

      return results
          .map(
            (row) => GeocoderResult(
              name: row['name'] as String,
              location: LatLng(row['lat'] as double, row['lng'] as double),
              zoom: row['zoom'] as int,
              type: row['type'] as String,
              detail: row['detail'] as String?,
            ),
          )
          .toList();
    } catch (e) {
      MapErrorHandler.logError('Search by type error: $e', context: 'geocoder');
      return [];
    }
  }

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
      const typePriority = [
        'place',
        'poi',
        'mountain_peak',
        'water_name',
        'transportation_name',
      ];
      final allResults = <GeocoderResult>[];

      for (final type in typePriority) {
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
  }

  /// Check if database is initialized
  bool get isInitialized => _database != null;
}
