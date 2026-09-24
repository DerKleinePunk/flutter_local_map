import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../api/place_search.dart';
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

/// [PlaceSearch] über eine lokale Namensdatenbank (SQLite mit FTS5).
///
/// Jede Instanz hält ihre eigene Verbindung. Wer sie anlegt, schließt sie
/// auch wieder mit [close].
class OfflineGeocoder implements PlaceSearch {
  Database? _database;
  String? _currentNamesDb;

  OfflineGeocoder();

  @override
  Future<List<GeocoderResult>> searchPlaces(String query, {int limit = 15}) =>
      searchPrioritized(query, limit: limit);

  /// Initialize geocoder with a names database
  /// Returns true if database was loaded successfully
  Future<bool> initialize(String namesDatabasePath) async {
    try {
      if (_database != null && _currentNamesDb == namesDatabasePath) {
        return true; // Already initialized with this database
      }

      final file = File(namesDatabasePath);
      if (!file.existsSync()) {
        MapErrorHandler.logDebug('Database not found: $namesDatabasePath', context: 'geocoder');
        return false;
      }

      // Close previous database if open
      await _database?.close();

      MapErrorHandler.logDebug('Attempting to open database: $namesDatabasePath', context: 'geocoder');
      _database = await openDatabase(namesDatabasePath, readOnly: true);
      _currentNamesDb = namesDatabasePath;

      // Verify tables exist
      final tables = await _database!.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('names', 'names_meta')",
      );

      if (tables.isEmpty) {
        MapErrorHandler.logDebug('Required tables not found in database', context: 'geocoder');
        await _database?.close();
        _database = null;
        _currentNamesDb = null;
        return false;
      }

      MapErrorHandler.logDebug('Initialized with $namesDatabasePath', context: 'geocoder');
      return true;
    } catch (e) {
      MapErrorHandler.logError('Error initializing: $e', context: 'geocoder');
      return false;
    }
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
      MapErrorHandler.logError('Prioritized search error: $e', context: 'geocoder');
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
        MapErrorHandler.logDebug('Copied database from assets to $dbPath', context: 'geocoder');
      }

      return dbPath;
    } catch (e) {
      MapErrorHandler.logError('Error copying database: $e', context: 'geocoder');
      return null;
    }
  }

  /// Close the database
  Future<void> close() async {
    await _database?.close();
    _database = null;
    _currentNamesDb = null;
  }

  /// Check if database is initialized
  bool get isInitialized => _database != null;
}
