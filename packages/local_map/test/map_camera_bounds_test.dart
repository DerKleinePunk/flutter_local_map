import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:local_map/src/services/map_camera_bounds.dart';

void main() {
  group('parseMbtilesBounds', () {
    test('liest west,sued,ost,nord in WGS84', () {
      final bounds = parseMbtilesBounds('10.28,52.12,10.78,52.42');

      expect(bounds, isNotNull);
      expect(bounds!.west, closeTo(10.28, 1e-9));
      expect(bounds.south, closeTo(52.12, 1e-9));
      expect(bounds.east, closeTo(10.78, 1e-9));
      expect(bounds.north, closeTo(52.42, 1e-9));
    });

    test('toleriert Leerzeichen zwischen den Werten', () {
      expect(parseMbtilesBounds(' 5.86 , 47.26 , 15.05 , 55.14 '), isNotNull);
    });

    test('verwirft unvollstaendige, unlesbare und unplausible Angaben', () {
      expect(parseMbtilesBounds('10.28,52.12,10.78'), isNull);
      expect(parseMbtilesBounds('west,52.12,10.78,52.42'), isNull);
      expect(parseMbtilesBounds(''), isNull);
      // Ost links von West bzw. Nord unter Sued
      expect(parseMbtilesBounds('10.78,52.12,10.28,52.42'), isNull);
      expect(parseMbtilesBounds('10.28,52.42,10.78,52.12'), isNull);
      // ausserhalb des Gradnetzes
      expect(parseMbtilesBounds('-190,52.12,10.78,52.42'), isNull);
      expect(parseMbtilesBounds('10.28,52.12,10.78,95'), isNull);
    });
  });

  group('centerWithinTiles', () {
    final braunschweig = LatLngBounds(
      const LatLng(52.12, 10.28),
      const LatLng(52.42, 10.78),
    );

    test('laesst eine Position innerhalb der Abdeckung unveraendert', () {
      const inside = LatLng(52.27, 10.53);

      expect(
        centerWithinTiles(configured: inside, bounds: braunschweig),
        equals(inside),
      );
    });

    test('rueckt eine Position ausserhalb in die Mitte der Kacheln', () {
      // Der Standardstart der App liegt in Hessen, die Kacheln decken
      // Braunschweig ab - genau der Fall, der auf dem Pi eine leere Karte
      // ergeben hat.
      const alsfeld = LatLng(50.6521, 9.1624);

      final result = centerWithinTiles(
        configured: alsfeld,
        bounds: braunschweig,
      );

      expect(result, isNot(equals(alsfeld)));
      expect(braunschweig.contains(result), isTrue);
      // LatLngBounds.center rechnet ueber Mercator, liegt also leicht
      // noerdlich der arithmetischen Mitte - daher die grobe Toleranz.
      expect(result.latitude, closeTo(52.27, 0.01));
      expect(result.longitude, closeTo(10.53, 0.01));
    });

    test('ohne bounds bleibt die konfigurierte Position stehen', () {
      const alsfeld = LatLng(50.6521, 9.1624);

      expect(
        centerWithinTiles(configured: alsfeld, bounds: null),
        equals(alsfeld),
      );
    });
  });

  group('effectiveCameraBounds', () {
    final braunschweig = LatLngBounds(
      const LatLng(52.12, 10.28),
      const LatLng(52.42, 10.78),
    );
    final hessen = LatLngBounds(
      const LatLng(49.3963, 7.7726),
      const LatLng(51.6569, 10.2358),
    );

    test('eine ausdrueckliche Vorgabe hat Vorrang', () {
      expect(
        effectiveCameraBounds(configured: hessen, tiles: braunschweig),
        equals(hessen),
      );
    });

    test('ohne Vorgabe halten die Kachelgrenzen die Kamera fest', () {
      expect(
        effectiveCameraBounds(configured: null, tiles: braunschweig),
        equals(braunschweig),
      );
    });

    test('ohne beides bleibt die Kamera frei', () {
      expect(
        effectiveCameraBounds(configured: null, tiles: null),
        isNull,
      );
    });
  });
}
