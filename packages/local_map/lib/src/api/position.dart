import 'package:latlong2/latlong.dart';

/// Eine Positionsmeldung, wie sie ein GPS-Empfänger liefert.
class PositionFix {
  final LatLng position;

  /// Kurs über Grund in Grad, 0 = Norden, im Uhrzeigersinn. `null`, wenn die
  /// Quelle keinen kennt. Bei Stillstand ist der Kurs eines GPS-Empfängers
  /// Rauschen - wer die Karte danach dreht, muss [speedMps] mit ansehen.
  final double? headingDegrees;

  /// Geschwindigkeit über Grund in m/s, `null` wenn unbekannt.
  final double? speedMps;

  /// Geschätzte Genauigkeit in Metern, `null` wenn unbekannt.
  final double? accuracyMeters;

  /// Zeitpunkt der Messung in UTC, `null` wenn die Quelle keinen liefert.
  final DateTime? timestampUtc;

  const PositionFix({
    required this.position,
    this.headingDegrees,
    this.speedMps,
    this.accuracyMeters,
    this.timestampUtc,
  });
}

/// Liefert die eigene Position an die Karte.
///
/// [GpsNmeaSimulatorService] spielt eine aufgezeichnete Fahrt ab. Ein
/// Fahrzeugsystem liest den Empfänger typischerweise in seinem Backend und
/// reicht die Meldungen über eine eigene Implementierung weiter.
abstract interface class PositionSource {
  /// Laufende Positionsmeldungen. Ein Broadcast-Stream, damit mehrere
  /// Abnehmer (Karte, Anzeige, Aufzeichnung) mithören können.
  Stream<PositionFix> get positions;
}
