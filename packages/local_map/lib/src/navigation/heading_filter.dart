import '../api/position.dart';

/// Macht aus dem GPS-Kurs einen Kurs, nach dem man eine Karte drehen kann.
///
/// Unter [minSpeedMps] ist der Kurs eines GPS-Empfängers Rauschen - im Stand
/// springt er beliebig umher. Dann bleibt der letzte gute Kurs stehen.
/// Darüber wird leicht geglättet, über den kürzeren Winkel, damit der
/// Übergang von 359° auf 1° kein Umlauf wird.
class HeadingFilter {
  HeadingFilter({this.minSpeedMps = 1.5, this.smoothing = 0.5})
    : assert(smoothing > 0 && smoothing <= 1);

  /// Darunter wird der Kurs eingefroren. 1,5 m/s sind gut 5 km/h.
  final double minSpeedMps;

  /// Anteil des neuen Kurses je Meldung, 1 = keine Glättung.
  final double smoothing;

  double? _heading;

  /// Der gefilterte Kurs, `null` solange keiner bekannt ist.
  double? get heading => _heading;

  /// Nimmt eine Meldung auf und liefert den gefilterten Kurs.
  double? update(PositionFix fix) {
    final raw = fix.headingDegrees;
    final speed = fix.speedMps;
    if (raw == null) {
      return _heading;
    }
    if (speed != null && speed < minSpeedMps) {
      // Im Stand: noch keinen Kurs? Dann lieber den verrauschten als keinen,
      // sonst zeigt der Pfeil beim Start einer Aufzeichnung nach Norden.
      return _heading ??= raw % 360;
    }
    final previous = _heading;
    if (previous == null) {
      return _heading = raw % 360;
    }
    return _heading =
        (previous + shortestTurn(previous, raw) * smoothing) % 360;
  }

  void reset() => _heading = null;
}

/// Kleinster Drehwinkel von [from] nach [to] in Grad, im Bereich -180..180.
double shortestTurn(double from, double to) {
  final d = (to - from) % 360;
  return d > 180 ? d - 360 : d;
}
