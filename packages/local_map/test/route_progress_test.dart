import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';

/// Eine L-foermige Route: 1 km nach Norden, dann 1 km nach Osten.
/// Auf 50 Grad Breite sind 0,009 Grad Breite etwa 1 km, 0,014 Grad Laenge
/// ebenfalls etwa 1 km.
RoutingResult _lRoute() => const RoutingResult(
  geometry: [
    RoutingPoint(lat: 50.000, lon: 9.000),
    RoutingPoint(lat: 50.0045, lon: 9.000),
    RoutingPoint(lat: 50.009, lon: 9.000), // Ecke, Index 2
    RoutingPoint(lat: 50.009, lon: 9.007),
    RoutingPoint(lat: 50.009, lon: 9.014), // Ziel, Index 4
  ],
  distanceMeters: 2000,
  durationSeconds: 200,
  maneuvers: [
    RoutingManeuver(
      instruction: 'Nach Norden fahren.',
      lengthKm: 1,
      timeSeconds: 100,
      type: 1,
      beginShapeIndex: 0,
    ),
    RoutingManeuver(
      instruction: 'Rechts abbiegen.',
      lengthKm: 1,
      timeSeconds: 100,
      type: 10,
      beginShapeIndex: 2,
    ),
    RoutingManeuver(
      instruction: 'Ziel erreicht.',
      lengthKm: 0,
      timeSeconds: 0,
      type: 4,
      beginShapeIndex: 4,
    ),
  ],
);

void main() {
  test('Mitte des ersten Schenkels: Rechts-Manoever 500 m voraus', () {
    final tracker = RouteTracker(_lRoute());
    expect(tracker.lengthMeters, closeTo(2000, 20));

    // Leicht neben der Route, wie ein echter Fix.
    final p = tracker.update(const LatLng(50.0045, 9.0001))!;

    expect(p.distanceToRouteMeters, closeTo(7, 1));
    expect(p.nextManeuver?.type, 10);
    expect(p.nextManeuverIndex, 1);
    expect(p.distanceToNextManeuverMeters, closeTo(500, 10));
    expect(p.remainingMeters, closeTo(1500, 20));
    expect(p.remainingSeconds, closeTo(150, 2));
  });

  test('nach der Ecke ist das Ziel das naechste Manoever', () {
    final tracker = RouteTracker(_lRoute());
    final p = tracker.update(const LatLng(50.009, 9.0035))!;

    expect(p.nextManeuver?.type, 4);
    expect(p.distanceToNextManeuverMeters, closeTo(750, 15));
    expect(p.segmentIndex, 2);
  });

  test('neben der Route: grosser Abstand wird gemeldet', () {
    final tracker = RouteTracker(_lRoute());
    final p = tracker.update(const LatLng(50.0045, 9.003))!;

    expect(p.distanceToRouteMeters, greaterThan(150));
  });

  test(
    'Hin und zurueck auf derselben Strasse bleibt auf der richtigen Seite',
    () {
      // Route nach Norden und auf derselben Linie zurueck.
      const route = RoutingResult(
        geometry: [
          RoutingPoint(lat: 50.000, lon: 9.000),
          RoutingPoint(lat: 50.003, lon: 9.000),
          RoutingPoint(lat: 50.006, lon: 9.000), // Wende, Index 2
          RoutingPoint(lat: 50.003, lon: 9.00001),
          RoutingPoint(lat: 50.000, lon: 9.00001),
        ],
        distanceMeters: 1334,
        durationSeconds: 120,
        maneuvers: [],
      );
      final tracker = RouteTracker(route);

      // Auf der Hinfahrt kurz vor der Wende ...
      expect(tracker.update(const LatLng(50.005, 9.0))!.segmentIndex, 1);
      // ... dann auf dem Rueckweg: die Position liegt geometrisch genauso nah
      // an der Hinfahrt, das Fenster haelt sie aber auf dem Rueckweg.
      expect(tracker.update(const LatLng(50.0055, 9.00001))!.segmentIndex, 2);
      expect(tracker.update(const LatLng(50.004, 9.00001))!.segmentIndex, 2);
      final back = tracker.update(const LatLng(50.002, 9.00001))!;
      expect(back.segmentIndex, 3);
      expect(back.remainingMeters, closeTo(222, 10));
    },
  );

  group('HeadingFilter', () {
    PositionFix fix(double heading, double speed) => PositionFix(
      position: const LatLng(50, 9),
      headingDegrees: heading,
      speedMps: speed,
    );

    test('im Stand bleibt der letzte gute Kurs', () {
      final f = HeadingFilter(smoothing: 1);
      expect(f.update(fix(90, 10)), 90);
      expect(f.update(fix(270, 0.2)), 90);
      expect(f.update(fix(12, 0.5)), 90);
      expect(f.update(fix(100, 10)), 100);
    });

    test('Glaettung ueber 0 Grad dreht den kurzen Weg', () {
      final f = HeadingFilter(smoothing: 0.5);
      f.update(fix(350, 10));
      expect(f.update(fix(10, 10)), closeTo(0, 1e-9));
    });

    test('ohne Geschwindigkeit wird der Kurs genommen', () {
      final f = HeadingFilter(smoothing: 1);
      expect(
        f.update(
          const PositionFix(position: LatLng(50, 9), headingDegrees: 45),
        ),
        45,
      );
    });

    test('shortestTurn', () {
      expect(shortestTurn(350, 10), 20);
      expect(shortestTurn(10, 350), -20);
      expect(shortestTurn(0, 180), 180);
    });
  });
}
