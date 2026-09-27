import 'package:flutter_map/flutter_map.dart' show TileCoordinates;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:local_map/src/services/prefetch_corridor.dart';

void main() {
  const alsfeld = LatLng(50.75, 9.27);

  test('Punkte liegen in Fahrtrichtung, nah vor fern', () {
    final points = corridorPoints(
      from: alsfeld,
      headingDegrees: 90, // nach Osten
      speedMps: 28, // ~100 km/h
      aheadSeconds: 60,
    );
    expect(points, hasLength(4)); // 15/30/45/60 s
    for (final p in points) {
      expect(p.latitude, closeTo(alsfeld.latitude, 0.01));
    }
    final lngs = points.map((p) => p.longitude).toList();
    expect(lngs, orderedEquals([...lngs]..sort()), reason: 'nah vor fern');
    // 28 m/s * 60 s = 1,68 km nach Osten.
    const d = Distance();
    expect(d.as(LengthUnit.Meter, alsfeld, points.last), closeTo(1680, 20));
  });

  test('Nachbarn liegen quer zur Fahrt', () {
    final (x, y) = tileOf(alsfeld, 14);
    // Fahrt nach Osten: Nachbarn in y.
    final east = corridorTiles(points: [alsfeld], headingDegrees: 90, zoom: 14);
    expect(east, [
      TileCoordinates(x, y, 14),
      TileCoordinates(x, y - 1, 14),
      TileCoordinates(x, y + 1, 14),
    ]);
    // Fahrt nach Norden: Nachbarn in x.
    final north = corridorTiles(points: [alsfeld], headingDegrees: 0, zoom: 14);
    expect(north, [
      TileCoordinates(x, y, 14),
      TileCoordinates(x - 1, y, 14),
      TileCoordinates(x + 1, y, 14),
    ]);
  });

  test('keine Doppelten, sichtbare fallen raus, hoechstens 12', () {
    final points = corridorPoints(
      from: alsfeld,
      headingDegrees: 90,
      speedMps: 40,
      aheadSeconds: 300,
      stepSeconds: 15,
    );
    final all = corridorTiles(points: points, headingDegrees: 90, zoom: 14);
    expect(all.length, maxPrefetchTiles);
    expect(all.toSet(), hasLength(all.length), reason: 'keine Doppelten');

    final first = all.first;
    final without = corridorTiles(
      points: points,
      headingDegrees: 90,
      zoom: 14,
      exclude: (t) => t == first,
    );
    expect(without, isNot(contains(first)));
    expect(without.length, maxPrefetchTiles);
  });

  test('tileOf trifft die bekannte Kachel', () {
    // Frankfurt bei z14 - Gegenprobe mit der Slippy-Map-Formel.
    final (x, y) = tileOf(const LatLng(50.1109, 8.6821), 14);
    expect((x, y), (8587, 5548));
  });

  test('am Rand der Welt wird nicht ueber den Pol geladen', () {
    final tiles = corridorTiles(
      points: [const LatLng(85.0, 0)],
      headingDegrees: 90,
      zoom: 2,
    );
    for (final t in tiles) {
      expect(t.y, inInclusiveRange(0, 3));
      expect(t.x, inInclusiveRange(0, 3));
    }
  });
}
