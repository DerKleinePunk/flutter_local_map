import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';

/// Sichert die Asset-Pfade des Packages ab. Beim Herausziehen aus der App
/// mussten sie das `packages/local_map/`-Praefix bekommen - ohne das laedt
/// MapView nur den Fallback-Style ohne Styling.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MapConfig.defaults verwendet die Package-Styles', () {
    expect(
      MapConfig.defaults.vectorStyleAssets,
      MapConfig.packageVectorStyleAssets,
    );
  });

  test('alle Style-Assets sind gebundelt und gueltiges JSON', () async {
    expect(MapConfig.packageVectorStyleAssets, isNotEmpty);

    for (final assetPath in MapConfig.packageVectorStyleAssets) {
      expect(
        assetPath,
        startsWith('packages/local_map/'),
        reason: 'Package-Assets brauchen das packages/<name>/-Praefix',
      );

      final styleText = await rootBundle.loadString(assetPath);
      final decoded = jsonDecode(styleText);

      expect(
        decoded,
        isA<Map<String, dynamic>>(),
        reason: '$assetPath sollte ein Style-Objekt sein',
      );
      expect(
        (decoded as Map<String, dynamic>)['layers'],
        isA<List<dynamic>>(),
        reason: '$assetPath sollte Layer enthalten',
      );
    }
  });

  test('initialVectorStyleIndex liegt im gueltigen Bereich', () {
    expect(
      MapConfig.defaults.initialVectorStyleIndex,
      lessThan(MapConfig.defaults.vectorStyleAssets.length),
    );
  });
}
