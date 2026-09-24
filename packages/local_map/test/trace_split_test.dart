import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' show Distance;
import 'package:local_map/local_map.dart';

/// Positionen der Beispieltour, wie der Simulator sie liefert.
List<LatLng> _tour() {
  final sim = GpsNmeaSimulatorService()
    ..loadFromLines(
      File('../../scripts/GpsTest/GPS-Adnan-Tour.txt').readAsLinesSync(),
    );
  final points = sim.loadedFixes.map((f) => f.position).toList();
  sim.dispose();
  return points;
}

RoutingResult _piece(int points, {required bool arrival}) => RoutingResult(
  geometry: [
    for (var i = 0; i < points; i++) RoutingPoint(lat: 50 + i / 1000, lon: 9),
  ],
  distanceMeters: 1000,
  durationSeconds: 60,
  maneuvers: [
    const RoutingManeuver(
      instruction: 'Losfahren',
      lengthKm: 1,
      timeSeconds: 60,
      type: 1,
      beginShapeIndex: 0,
    ),
    if (arrival)
      RoutingManeuver(
        instruction: 'Ziel erreicht',
        lengthKm: 0,
        timeSeconds: 0,
        type: 4,
        beginShapeIndex: points - 1,
      ),
  ],
);

void main() {
  test('eine gerade Spur bleibt ein Stueck', () {
    final line = [for (var i = 0; i < 50; i++) LatLng(50 + i * 0.0005, 9)];
    expect(splitTraceAtOverlaps(line), hasLength(1));
  });

  test('hin und zurueck wird am Umkehrpunkt geteilt', () {
    final out = [for (var i = 0; i <= 20; i++) LatLng(50 + i * 0.0005, 9)];
    final back = [
      for (var i = 19; i >= 0; i--) LatLng(50 + i * 0.0005, 9.00001),
    ];
    final pieces = splitTraceAtOverlaps([...out, ...back]);

    expect(pieces, hasLength(2));
    // Beide Stuecke teilen sich den Wendepunkt.
    expect(pieces[0].last, pieces[1].first);
    // Die Ueberlappung faellt auf, wenn die Rueckfahrt etwa die Haelfte von
    // minPathGapMeters am Umkehrpunkt vorbei ist.
    expect(
      const Distance()(pieces[0].last, const LatLng(50.01, 9)),
      lessThan(250),
    );
  });

  test('die Beispieltour wird am Umkehrpunkt geteilt', () {
    final tour = _tour();
    final pieces = splitTraceAtOverlaps(tour);

    expect(pieces.length, greaterThanOrEqualTo(2));
    // Der suedlichste Punkt (Wende nach etwa der Haelfte) liegt an einer
    // Nahtstelle.
    final south = tour.reduce((a, b) => a.latitude < b.latitude ? a : b);
    final seams = [for (final p in pieces.skip(1)) p.first];
    final nearest = seams
        .map((s) => const Distance()(s, south))
        .reduce((a, b) => a < b ? a : b);
    expect(nearest, lessThan(200));
    // Nichts geht verloren: alle Punkte stecken in den Stuecken.
    final total = pieces.fold<int>(0, (n, p) => n + p.length);
    expect(total - (pieces.length - 1), tour.length);
  });

  test('joinRoutes verschiebt Indizes und laesst das Zwischenziel weg', () {
    final joined = joinRoutes([
      _piece(3, arrival: true),
      _piece(4, arrival: true),
    ]);

    expect(joined.geometry, hasLength(7));
    expect(joined.distanceMeters, 2000);
    expect(joined.durationSeconds, 120);
    expect(joined.maneuvers.map((m) => m.type), [1, 1, 4]);
    expect(joined.maneuvers[1].beginShapeIndex, 3);
    expect(joined.maneuvers[2].beginShapeIndex, 6);
  });

  // Gegen einen echten Valhalla-Server, z. B. per SSH-Tunnel zum Pi:
  //   ssh -L 8002:127.0.0.1:8002 jeep-pi
  //   VALHALLA_URL=http://127.0.0.1:8002 flutter test test/trace_split_test.dart
  final valhalla = Platform.environment['VALHALLA_URL'];
  test(
    'die ganze Tour kommt vollstaendig als Route zurueck',
    () async {
      final service = ValhallaRoutingService(baseUri: Uri.parse(valhalla!));
      final route = await service.routeAlongTrace(_tour());

      // Die Tour ist rund 45 km lang; ohne Teilen kamen 22,7 km zurueck.
      expect(route.distanceMeters, greaterThan(40000));
      expect(route.maneuvers.where((m) => m.type == 4), hasLength(1));
      expect(route.maneuvers.last.type, 4);
    },
    skip: valhalla == null ? 'VALHALLA_URL nicht gesetzt' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
