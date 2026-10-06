import 'package:latlong2/latlong.dart';

/// Repräsentiert ein Koordinatenpaar im WGS84-Format.
class RoutingPoint {
  final double lat;
  final double lon;

  const RoutingPoint({required this.lat, required this.lon});

  factory RoutingPoint.fromLatLng(LatLng value) =>
      RoutingPoint(lat: value.latitude, lon: value.longitude);

  LatLng toLatLng() => LatLng(lat, lon);
}

/// Einzelnes Turn-by-Turn-Manöver einer Route.
class RoutingManeuver {
  final String instruction;
  final double lengthKm;
  final int timeSeconds;

  /// Manövertyp nach Valhalla-Zählung (z. B. 10 = rechts abbiegen). Andere
  /// Anbieter bilden ihre Typen darauf ab oder lassen das Feld leer.
  final int? type;

  /// Index in [RoutingResult.geometry], an dem das Manöver beginnt. Damit
  /// lässt sich die Position entlang der Route dem nächsten Manöver zuordnen.
  final int? beginShapeIndex;

  /// Straßennamen, auf die das Manöver führt.
  final List<String> streetNames;

  /// Sprechtexte für Ansagen, in der Sprache des Routers. `null`, wenn der
  /// Anbieter keine liefert - dann gilt [instruction].
  ///
  /// [verbalAlert] ist die Vorwarnung ("Links auf Amthof abbiegen."), ohne
  /// Entfernung; [verbalPre] die Ansage am Manöver selbst; [verbalPost] der
  /// Satz danach ("200 Meter weiter auf B 62."). Valhalla:
  /// `verbal_transition_alert_instruction`, `verbal_pre_transition_instruction`,
  /// `verbal_post_transition_instruction`.
  final String? verbalAlert;
  final String? verbalPre;
  final String? verbalPost;

  const RoutingManeuver({
    required this.instruction,
    required this.lengthKm,
    required this.timeSeconds,
    required this.type,
    this.beginShapeIndex,
    this.streetNames = const <String>[],
    this.verbalAlert,
    this.verbalPre,
    this.verbalPost,
  });
}

/// Ergebnis einer Routingabfrage.
class RoutingResult {
  final List<RoutingPoint> geometry;
  final double distanceMeters;
  final int durationSeconds;
  final List<RoutingManeuver> maneuvers;

  const RoutingResult({
    required this.geometry,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.maneuvers,
  });
}

/// Fehlerklasse für nachvollziehbare Routing-Fehlermeldungen.
class RoutingException implements Exception {
  final String message;

  const RoutingException(this.message);

  @override
  String toString() => 'RoutingException: $message';
}

/// Berechnet Routen für die Karte.
///
/// Die Karte kennt nur diese Schnittstelle. Woher die Route kommt, entscheidet
/// der Gastgeber: [ValhallaRoutingService] fragt einen Valhalla-Server per
/// HTTP, ein Fahrzeugsystem kann ebenso gut sein eigenes Backend fragen.
abstract interface class RoutingProvider {
  /// Berechnet eine Route von [start] nach [end].
  ///
  /// Ohne [start] fährt die Route von der aktuellen Position los - woher die
  /// kommt, weiß der Anbieter (ein Backend kennt seinen GPS-Fix). Ein
  /// Anbieter ohne eigene Position wirft dann [RoutingException].
  ///
  /// [startHeadingDegrees] ist der Kurs am Start (0 = Norden, im
  /// Uhrzeigersinn), wenn das Fahrzeug gerade fährt. Der Anbieter soll die
  /// Route dann in diese Richtung beginnen lassen statt mit Wenden - wichtig
  /// beim Neuberechnen nach dem Verlassen der Route. `null` = unbekannt
  /// oder im Stand; ein Anbieter darf den Wert auch übergehen.
  ///
  /// Wirft [RoutingException], wenn keine Route zustande kommt.
  Future<RoutingResult> route({
    LatLng? start,
    required LatLng end,
    double? startHeadingDegrees,
  });

  /// Ob der Anbieter gerade Anfragen annimmt.
  Future<bool> isAvailable();
}
