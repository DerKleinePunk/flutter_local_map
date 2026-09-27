import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart' show TileCoordinates;
import 'package:latlong2/latlong.dart';

/// Rechnet aus, welche Kacheln beim Vorab-Laden in Fahrtrichtung dran sind
/// (`MapConfig.prefetchAheadSeconds`). Reine Geometrie, damit sie sich ohne
/// Karte testen lässt; das Laden selbst macht `MapView` über den
/// `VectorTileController` des Kachel-Layers.

/// Abstand der Stützpunkte auf der extrapolierten Linie.
const int prefetchStepSeconds = 15;

/// Mehr Kacheln werden je Fix nie angefordert - die Obergrenze aus dem
/// Entwurf, gegen die auch das Speicherbudget gerechnet ist.
const int maxPrefetchTiles = 12;

/// Die Positionen in [stepSeconds]-Schritten bis [aheadSeconds] voraus, bei
/// gehaltenem Kurs und Tempo. Nah vor fern, damit beim Kappen auf
/// [maxPrefetchTiles] das Nächstliegende gewinnt.
List<LatLng> corridorPoints({
  required LatLng from,
  required double headingDegrees,
  required double speedMps,
  required int aheadSeconds,
  int stepSeconds = prefetchStepSeconds,
}) {
  const distance = Distance();
  return [
    for (var t = stepSeconds; t <= aheadSeconds; t += stepSeconds)
      distance.offset(from, speedMps * t, headingDegrees),
  ];
}

/// Die Kacheln zu [points] auf [zoom], je Punkt mit den beiden Nachbarn quer
/// zur Fahrtrichtung, ohne Doppelte und ohne [exclude] (die ohnehin
/// sichtbaren), gekappt auf [maxPrefetchTiles]. Die Reihenfolge der Punkte
/// bleibt erhalten.
List<TileCoordinates> corridorTiles({
  required List<LatLng> points,
  required double headingDegrees,
  required int zoom,
  bool Function(TileCoordinates)? exclude,
}) {
  final worldTiles = 1 << zoom;
  // Quer zur Fahrt: läuft sie eher Nord-Süd, liegen die Nachbarn in x,
  // sonst in y.
  final northSouth =
      math.cos(headingDegrees * math.pi / 180).abs() >=
      math.sin(headingDegrees * math.pi / 180).abs();
  final seen = <TileCoordinates>{};
  final tiles = <TileCoordinates>[];
  void add(int x, int y) {
    if (y < 0 || y >= worldTiles || tiles.length >= maxPrefetchTiles) return;
    final tile = TileCoordinates(
      ((x % worldTiles) + worldTiles) % worldTiles,
      y,
      zoom,
    );
    if (!seen.add(tile)) return;
    if (exclude != null && exclude(tile)) return;
    tiles.add(tile);
  }

  for (final point in points) {
    final (x, y) = tileOf(point, zoom);
    add(x, y);
    if (northSouth) {
      add(x - 1, y);
      add(x + 1, y);
    } else {
      add(x, y - 1);
      add(x, y + 1);
    }
  }
  return tiles;
}

/// Kachel von [position] auf [zoom] im Schema der Web-Karten.
(int, int) tileOf(LatLng position, int zoom) {
  final n = 1 << zoom;
  final x = ((position.longitude + 180) / 360 * n).floor();
  final latRad = position.latitude * math.pi / 180;
  final y =
      ((1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
              2 *
              n)
          .floor();
  return (x.clamp(0, n - 1), y.clamp(0, n - 1));
}
