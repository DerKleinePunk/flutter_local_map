import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';
import 'package:map_local/route_format.dart';

void main() {
  test('Dauer in Stunden und Minuten statt nur Minuten', () {
    expect(formatDuration(289 * 60), '4 h 49 min');
    expect(formatDuration(120 * 60), '2 h');
    expect(formatDuration(35 * 60), '35 min');
    expect(formatDuration(59.6 * 60), '1 h');
    expect(formatDuration(10), '1 min');
  });

  test('Entfernung: Meter, eine Nachkommastelle, ab 10 km ganze Kilometer', () {
    expect(formatDistance(347), '350 m');
    expect(formatDistance(996), '1,0 km', reason: 'nicht "1000 m"');
    expect(formatDistance(3240), '3,2 km');
    expect(formatDistance(500600), '501 km');
  });

  test('Ankunft heute, morgen und spaeter', () {
    final now = DateTime(2026, 9, 26, 17, 31);
    expect(formatArrival(289 * 60, now: now), 'Ankunft 22:20');
    expect(formatArrival(7 * 3600, now: now), 'Ankunft morgen 00:31');
    expect(formatArrival(40 * 3600, now: now), 'Ankunft 28.9. 09:31');
  });

  test('Stau voraus, mittendrin und Vollsperrung', () {
    RouteTrafficSpan span({
      TrafficSeverity severity = TrafficSeverity.heavy,
      int delay = 16 * 60,
    }) => RouteTrafficSpan(
      incident: const TrafficIncident(
        id: 'x',
        kind: TrafficIncidentKind.jam,
        road: 'A3',
        title: 'A3',
      ),
      startMeters: 12000,
      endMeters: 14400,
      points: const [],
      severity: severity,
      delaySeconds: delay,
    );
    expect(formatTrafficSpan(span()), 'Stau 2,4 km • +16 min • in 12 km');
    expect(
      formatTrafficSpan(span(), traveledMeters: 13600),
      'Stau noch 800 m • +5 min',
    );
    expect(
      formatTrafficSpan(
        span(severity: TrafficSeverity.closed, delay: 0),
        traveledMeters: 8800,
      ),
      'Vollsperrung • in 3,2 km',
    );
  });
}
