import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'map_error_handler.dart';

/// Liest den `bounds`-Eintrag der MBTiles-Metadaten: "west,sued,ost,nord"
/// in WGS84.
///
/// Gibt `null` zurueck, wenn der Eintrag fehlt, nicht vier Zahlen enthaelt
/// oder unplausibel ist. Der Aufrufer behaelt dann seine konfigurierte
/// Startposition.
LatLngBounds? parseMbtilesBounds(String raw) {
  final parts = raw.split(',');
  if (parts.length != 4) {
    return null;
  }

  final values = <double>[];
  for (final part in parts) {
    final value = double.tryParse(part.trim());
    if (value == null) {
      return null;
    }
    values.add(value);
  }

  final west = values[0];
  final south = values[1];
  final east = values[2];
  final north = values[3];

  final inRange = west >= -180 && east <= 180 && south >= -90 && north <= 90;
  if (!inRange || west >= east || south >= north) {
    return null;
  }

  return LatLngBounds(LatLng(south, west), LatLng(north, east));
}

/// Haelt die Startkamera in der Abdeckung der MBTiles.
///
/// Liegt [configured] ausserhalb von [bounds], zeigt die Karte sonst eine
/// leere Flaeche und meldet nichts - dieser Fall wurde in diesem Projekt
/// schon zweimal als Renderfehler missgedeutet. Statt dessen ruecken wir die
/// Kamera in die Mitte der vorhandenen Kacheln und schreiben eine Zeile ins
/// Log, die auch im Release sichtbar ist.
LatLng centerWithinTiles({
  required LatLng configured,
  required LatLngBounds? bounds,
}) {
  if (bounds == null || bounds.contains(configured)) {
    return configured;
  }

  final fallback = bounds.center;
  MapErrorHandler.logError(
    'Startposition ${configured.latitude}, ${configured.longitude} liegt '
    'ausserhalb der Kartenabdeckung '
    '(${bounds.west}, ${bounds.south}) bis (${bounds.east}, ${bounds.north}). '
    'Kamera auf ${fallback.latitude}, ${fallback.longitude} gesetzt - '
    'passen die MBTiles zum erwarteten Gebiet?',
    context: 'Camera bounds',
  );
  return fallback;
}
