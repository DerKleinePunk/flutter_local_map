import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';

void main() {
  group('MapConfig.labelRotationStep', () {
    test('is off by default, as before (#1)', () {
      expect(MapConfig().labelRotationStep, 0);
      expect(MapConfig.hessen.labelRotationStep, 0);
    });

    test('copyWith sets it and keeps it otherwise', () {
      final turned = MapConfig().copyWith(labelRotationStep: 45);

      expect(turned.labelRotationStep, 45);
      expect(turned.copyWith(panBuffer: 1).labelRotationStep, 45);
      expect(turned.copyWith(labelRotationStep: 0).labelRotationStep, 0);
    });
  });
}
