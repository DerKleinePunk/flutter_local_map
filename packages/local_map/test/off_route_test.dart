import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';

/// Eine gerade Route 2 km nach Norden. Auf 50 Grad Breite sind 0,009 Grad
/// Breite etwa 1 km, 0,0007 Grad Laenge etwa 50 m.
RoutingResult _northRoute() => const RoutingResult(
  geometry: [
    RoutingPoint(lat: 50.000, lon: 9.000),
    RoutingPoint(lat: 50.009, lon: 9.000),
    RoutingPoint(lat: 50.018, lon: 9.000),
  ],
  distanceMeters: 2000,
  durationSeconds: 200,
  maneuvers: [],
);

/// Laenge fuer [meters] Meter nach Osten auf 50 Grad Breite.
double _east(double meters) => meters / (111319.49 * 0.6428);

/// Breite fuer [meters] Meter nach Norden.
double _north(double meters) => meters / 111319.49;

const double _driving = 10; // m/s, 36 km/h

/// Faehrt [fixes] Fixes ab [startMeters] nach Norden, [offsetMeters] neben
/// der Route, und liefert die offRoute-Werte.
List<bool> _drive(
  RouteTracker tracker, {
  required int fixes,
  double startMeters = 200,
  double offsetMeters = 0,
  double heading = 0,
  double? speed = _driving,
}) {
  final result = <bool>[];
  for (var i = 0; i < fixes; i++) {
    final p = tracker.update(
      LatLng(50 + _north(startMeters + i * 10), 9 + _east(offsetMeters)),
      headingDegrees: heading,
      speedMps: speed,
    )!;
    result.add(p.offRoute);
  }
  return result;
}

void main() {
  test('auf der Route mit normalem GPS-Rauschen: nie verlassen', () {
    final tracker = RouteTracker(_northRoute());
    final offsets = <double>[5, -8, 12, -3, 15, -10, 7, 0, -14, 9];
    for (var i = 0; i < offsets.length; i++) {
      final p = tracker.update(
        LatLng(50 + _north(200 + i * 10), 9 + _east(offsets[i])),
        headingDegrees: 0,
        speedMps: _driving,
      )!;
      expect(p.offRoute, isFalse, reason: 'Fix $i');
    }
  });

  test('ein einzelner GPS-Sprung loest nicht aus', () {
    final tracker = RouteTracker(_northRoute());
    _drive(tracker, fixes: 3);
    // Zwei Fixes 120 m daneben, dann wieder auf der Route.
    expect(_drive(tracker, fixes: 2, startMeters: 230, offsetMeters: 120), [
      false,
      false,
    ]);
    expect(_drive(tracker, fixes: 3, startMeters: 250), [false, false, false]);
  });

  test('echtes Abbiegen: nach dem dritten Fix daneben verlassen', () {
    final tracker = RouteTracker(_northRoute());
    _drive(tracker, fixes: 3);
    expect(
      _drive(
        tracker,
        fixes: 4,
        startMeters: 230,
        offsetMeters: 80,
        heading: 90,
      ),
      [false, false, true, true],
    );
  });

  test('zurueck auf der Route: nach zwei Fixes wieder darauf', () {
    final tracker = RouteTracker(_northRoute());
    _drive(tracker, fixes: 3, offsetMeters: 80);
    expect(tracker.update(LatLng(50 + _north(240), 9))!.offRoute, isTrue);
    // 30 m daneben ist zwischen den Schwellen: bleibt verlassen.
    expect(_drive(tracker, fixes: 2, startMeters: 250, offsetMeters: 30), [
      true,
      true,
    ]);
    expect(_drive(tracker, fixes: 2, startMeters: 270), [true, false]);
  });

  test('im Stand bleibt der Zustand, wie er ist', () {
    final tracker = RouteTracker(_northRoute());
    // Parkplatz 100 m neben der Route, stehend.
    expect(
      _drive(tracker, fixes: 5, offsetMeters: 100, speed: 0.3),
      everyElement(isFalse),
    );
    // Verlassen, dann im Stand zurueck auf die Route: bleibt verlassen.
    _drive(tracker, fixes: 3, offsetMeters: 100);
    expect(
      _drive(tracker, fixes: 3, startMeters: 300, speed: 0),
      everyElement(isTrue),
    );
  });

  test('gewendet: auf der Route in Gegenrichtung gilt als verlassen', () {
    final tracker = RouteTracker(_northRoute());
    _drive(tracker, fixes: 5);
    expect(_drive(tracker, fixes: 3, startMeters: 240, heading: 180), [
      false,
      false,
      true,
    ]);
  });

  test('schlechte Genauigkeit hebt die Schwelle an', () {
    final tracker = RouteTracker(_northRoute());
    for (var i = 0; i < 5; i++) {
      final p = tracker.update(
        LatLng(50 + _north(200 + i * 10), 9 + _east(70)),
        headingDegrees: 0,
        speedMps: _driving,
        accuracyMeters: 40,
      )!;
      expect(p.offRoute, isFalse, reason: '70 m < 2 x 40 m');
    }
  });

  test('nach der Ankunft gilt die Route nie mehr als verlassen', () {
    final tracker = RouteTracker(_northRoute());
    _drive(tracker, fixes: 1, startMeters: 1990);
    // Am Ziel vorbei und weiter nach Osten.
    expect(
      _drive(tracker, fixes: 5, startMeters: 2000, offsetMeters: 200),
      everyElement(isFalse),
    );
  });

  test('ohne Kurs und Geschwindigkeit zaehlt allein der Abstand', () {
    final tracker = RouteTracker(_northRoute());
    final values = [
      for (var i = 0; i < 3; i++)
        tracker
            .update(LatLng(50 + _north(200 + i * 10), 9 + _east(80)))!
            .offRoute,
    ];
    expect(values, [false, false, true]);
  });

  test('eigene Schwellen aus OffRoutePolicy', () {
    final tracker = RouteTracker(
      _northRoute(),
      offRoutePolicy: const OffRoutePolicy(
        enterMeters: 20,
        exitMeters: 10,
        enterFixes: 1,
      ),
    );
    expect(_drive(tracker, fixes: 1, offsetMeters: 30), [true]);
  });
}
