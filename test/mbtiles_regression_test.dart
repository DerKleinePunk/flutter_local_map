import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  group('MBTiles Regression Tests', () {
    test('Raster MBTiles metadata can be read correctly', () {
      final rasterPath = 'map/tiles-germany/hessen_raster.mbtiles';
      
      expect(File(rasterPath).existsSync(), isTrue, reason: 'Raster MBTiles file should exist');
      
      final db = sqlite3.open(rasterPath, mode: OpenMode.readOnly);
      final rows = db.select("SELECT name, value FROM metadata WHERE name = 'format';");
      
      expect(rows, isNotEmpty, reason: 'Metadata should contain format entry');
      
      final formatRow = rows.firstWhere((row) => row['name'] == 'format');
      final format = formatRow['value'].toString().toLowerCase();
      
      expect(['png', 'jpg', 'jpeg', 'webp'].contains(format), isTrue, 
        reason: 'Format should be a known raster format, got: $format');
      
      db.close();
    });

    test('Vector MBTiles metadata can be read correctly', () {
      final vectorPath = 'map/tiles-germany/hessen.mbtiles';
      
      expect(File(vectorPath).existsSync(), isTrue, reason: 'Vector MBTiles file should exist');
      
      final db = sqlite3.open(vectorPath, mode: OpenMode.readOnly);
      final rows = db.select("SELECT name, value FROM metadata WHERE name = 'format';");
      
      expect(rows, isNotEmpty, reason: 'Metadata should contain format entry');
      
      final formatRow = rows.firstWhere((row) => row['name'] == 'format');
      final format = formatRow['value'].toString().toLowerCase();
      
      expect(format, equals('pbf'), reason: 'Vector format should be pbf, got: $format');
      
      db.close();
    });
  });
}
