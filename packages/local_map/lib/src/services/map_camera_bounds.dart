import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'map_error_handler.dart';

/// Start, wenn weder eine Position konfiguriert ist noch die MBTiles ihre
/// Grenzen angeben.
const LatLng fallbackCenter = LatLng(0, 0);

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
///
/// Ohne [configured] ist die Mitte der Kacheln der Start; fehlen auch die
/// Kachelgrenzen, bleibt nur [fallbackCenter].
LatLng centerWithinTiles({
  required LatLng? configured,
  required LatLngBounds? bounds,
}) {
  if (configured == null) {
    return bounds?.center ?? fallbackCenter;
  }
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

/// Waehlt die Grenzen, in denen sich die Kamera bewegen darf.
///
/// Vorrang hat eine ausdrueckliche Vorgabe aus der [configured]-Konfiguration.
/// Fehlt sie, nehmen wir die Abdeckung der MBTiles: ausserhalb davon gibt es
/// ohnehin nichts zu sehen, und auf einem kleinen Ausschnitt ist die Karte
/// sonst mit zwei Tastendruecken ins Leere geschoben.
LatLngBounds? effectiveCameraBounds({
  required LatLngBounds? configured,
  required LatLngBounds? tiles,
}) => configured ?? tiles;

/// Kleinste Zoomstufe, bei der die Kacheln noch etwa eine Kachelbreite
/// (256 px) auf dem Schirm einnehmen.
///
/// Weiter herausgezoomt schrumpft ein kleiner Ausschnitt zu einem Punkt, und
/// der Anwender sieht eine leere Flaeche, ohne zu erkennen, wohin er zurueck
/// muss. Gerechnet wird ueber die Laengengrad-Spanne, weil die x-Achse in
/// Mercator linear davon abhaengt.
///
/// `null`, wenn es keine Kachelgrenzen gibt oder sie den ganzen Globus
/// umspannen - dann gibt es nichts zu begrenzen.
double? minZoomForBounds(LatLngBounds? bounds) {
  if (bounds == null) {
    return null;
  }

  final lonSpan = bounds.east - bounds.west;
  if (lonSpan <= 0 || lonSpan >= 360) {
    return null;
  }

  return math.log(360 / lonSpan) / math.ln2;
}

/// Die Zoom-Untergrenze, mit der die Karte tatsaechlich arbeitet.
///
/// Nimmt die groessere von [fromMetadata] und der aus [tiles] abgeleiteten
/// Grenze, ueberschreitet dabei aber nie [max] - sonst liesse sich die Karte
/// gar nicht mehr darstellen.
double effectiveMinZoom({
  required double fromMetadata,
  required double max,
  required LatLngBounds? tiles,
}) {
  final fromTiles = minZoomForBounds(tiles);
  if (fromTiles == null || fromTiles <= fromMetadata) {
    return fromMetadata;
  }
  return math.min(fromTiles, max);
}

/// Zoomstufe, auf die die Karte nach der Auswahl eines Suchtreffers springt.
///
/// [configured] ist der feste Wert aus der Konfiguration; `null` nimmt
/// [fromResult], die Zoomstufe, die der Geocoder zum Treffer liefert. Die ist
/// fuer eine Navigation zu grob - eine Stadt kommt mit z7, ein Dorf mit z10.
/// Das Ergebnis bleibt zwischen [min] und [max], also innerhalb dessen, was
/// die Kacheln hergeben.
double searchResultZoom({
  required double? configured,
  required int fromResult,
  required double min,
  required double max,
}) => (configured ?? fromResult.toDouble()).clamp(min, max);

/// Zoomstufe nach einem Druck auf die Zoomknoepfe.
///
/// [direction] ist +1 zum Hinein- und -1 zum Herauszoomen. Das Ergebnis bleibt
/// zwischen [min] und [max]; steht die Kamera schon am Anschlag, kommt der
/// unveraenderte Wert zurueck, und der Aufrufer kann sich die Bewegung sparen.
double steppedZoom({
  required double current,
  required int direction,
  required double min,
  required double max,
}) => (current + direction).clamp(min, max);
