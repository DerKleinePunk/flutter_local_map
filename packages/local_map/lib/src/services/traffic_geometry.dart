// Geometrie-Helfer der Verkehrsdienste. Nicht exportiert.
import 'package:latlong2/latlong.dart';

/// Zahl aus einer Zahl oder aus Text.
double? parseNumber(Object? value) {
  if (value is num) return value.isFinite ? value.toDouble() : null;
  if (value is String) return double.tryParse(value.trim());
  return null;
}

/// Ein gültiger Punkt oder `null`. 0/0 gilt als fehlend, nicht als Ort im
/// Golf von Guinea.
LatLng? validLatLng(double? lat, double? lon) {
  if (lat == null || lon == null) return null;
  if (lat.abs() > 90 || lon.abs() > 180) return null;
  if (lat == 0 && lon == 0) return null;
  return LatLng(lat, lon);
}

/// Ein GeoJSON-Punkt `[lon, lat]`.
LatLng? geoJsonPosition(Object? coordinates) {
  if (coordinates is! List || coordinates.length < 2) return null;
  return validLatLng(parseNumber(coordinates[1]), parseNumber(coordinates[0]));
}

/// Eine GeoJSON-LineString-Geometrie, `[lon, lat]` je Punkt. Leer, wenn
/// es keine Linie mit mindestens zwei Punkten ist.
List<LatLng> geoJsonLine(Object? geometry) {
  if (geometry is! Map || geometry['type'] != 'LineString') return const [];
  final coordinates = geometry['coordinates'];
  if (coordinates is! List) return const [];
  final points = <LatLng>[];
  for (final c in coordinates) {
    final p = geoJsonPosition(c);
    if (p != null) points.add(p);
  }
  return points.length >= 2 ? points : const [];
}

/// Punkte, die näher als 40 m am vorigen liegen, fallen weg. Ein Stau
/// kommt mit Hunderten Stützpunkten; für eine farbige Linie und den
/// Abgleich mit der Route reicht ein Bruchteil.
List<LatLng> thinLine(List<LatLng> line) {
  if (line.length <= 2) return line;
  const distance = Distance();
  final result = <LatLng>[line.first];
  for (var i = 1; i < line.length - 1; i++) {
    if (distance.as(LengthUnit.Meter, result.last, line[i]) >= _thinMeters) {
      result.add(line[i]);
    }
  }
  result.add(line.last);
  return result;
}

const double _thinMeters = 40;
