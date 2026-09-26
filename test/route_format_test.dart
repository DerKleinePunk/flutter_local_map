import 'package:flutter_test/flutter_test.dart';
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
}
