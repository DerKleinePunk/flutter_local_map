import 'heading_filter.dart';

/// Wann die Position als „von der Route abgekommen“ gilt und wie oft dann
/// neu berechnet wird.
///
/// Die Vorgaben sind für ein Auto mit GPS-Maus bei 1 Hz gewählt: Ein
/// einzelner Sprung des Empfängers oder eine weit ausgeholte Kreuzung löst
/// nichts aus, ein echtes Abbiegen nach etwa drei Sekunden.
class OffRoutePolicy {
  const OffRoutePolicy({
    this.enterMeters = 50,
    this.exitMeters = 25,
    this.enterFixes = 3,
    this.exitFixes = 2,
    this.minSpeedMps = 1.5,
    this.wrongWayDegrees = 120,
    this.arrivalMeters = 30,
    this.reroute = true,
    this.rerouteIntervals = const [
      Duration(seconds: 15),
      Duration(seconds: 30),
      Duration(seconds: 60),
    ],
  }) : assert(exitMeters <= enterMeters),
       assert(enterFixes > 0 && exitFixes > 0);

  /// Weiter als so viele Meter von der Route zählt ein Fix als „daneben“.
  /// Meldet der Empfänger eine schlechtere Genauigkeit, gilt das Doppelte
  /// davon.
  final double enterMeters;

  /// Näher als so viele Meter zählt ein Fix wieder als „auf der Route“.
  final double exitMeters;

  /// So viele Fixes hintereinander daneben, dann gilt die Route als verlassen.
  final int enterFixes;

  /// So viele Fixes hintereinander auf der Route, dann gilt sie wieder.
  final int exitFixes;

  /// Darunter steht das Fahrzeug: Der Zustand bleibt, wie er ist, und es
  /// wird nicht neu berechnet. 1,5 m/s sind gut 5 km/h.
  final double minSpeedMps;

  /// Weicht der Kurs um mehr als so viele Grad von der Richtung der Route
  /// ab, zählt der Fix auch auf der Route als „daneben“ - wer gewendet hat,
  /// fährt auf derselben Straße in die falsche Richtung.
  final double wrongWayDegrees;

  /// Näher am Ziel als so viele Meter ist die Fahrt angekommen. Danach gilt
  /// die Route nie mehr als verlassen, auch wenn es weitergeht.
  final double arrivalMeters;

  /// Ob [LocalMapController] nach dem Verlassen selbst neu berechnet.
  final bool reroute;

  /// Abstände zwischen zwei Neuberechnungen. Nach jedem Fehlschlag gilt der
  /// nächste Eintrag, der letzte bleibt; ein Erfolg fängt wieder vorn an.
  final List<Duration> rerouteIntervals;
}

/// Entscheidet Fix für Fix, ob die Route verlassen ist. Gehört zu einer
/// Route; eine neue Route bekommt einen neuen Detektor.
class OffRouteDetector {
  OffRouteDetector([this.policy = const OffRoutePolicy()]);

  final OffRoutePolicy policy;

  bool _offRoute = false;
  bool _arrived = false;
  int _streak = 0;

  bool get offRoute => _offRoute;

  /// Nimmt einen Fix auf und liefert den neuen Zustand.
  ///
  /// [distanceMeters] ist der Abstand zur Route, [routeBearing] die Richtung
  /// des Routenabschnitts dort, [remainingMeters] der Restweg. Ohne
  /// [speedMps] gilt das Fahrzeug als fahrend, ohne [headingDegrees] zählt
  /// nur der Abstand.
  bool update({
    required double distanceMeters,
    required double remainingMeters,
    double? routeBearing,
    double? headingDegrees,
    double? speedMps,
    double? accuracyMeters,
  }) {
    if (remainingMeters <= policy.arrivalMeters) {
      _arrived = true;
    }
    if (_arrived) {
      _offRoute = false;
      _streak = 0;
      return false;
    }
    if (speedMps != null && speedMps < policy.minSpeedMps) {
      return _offRoute;
    }

    final enter = accuracyMeters == null
        ? policy.enterMeters
        : (accuracyMeters * 2 > policy.enterMeters
              ? accuracyMeters * 2
              : policy.enterMeters);
    final wrongWay =
        routeBearing != null &&
        headingDegrees != null &&
        shortestTurn(routeBearing, headingDegrees).abs() >
            policy.wrongWayDegrees;

    if (_offRoute) {
      final back = distanceMeters < policy.exitMeters && !wrongWay;
      _streak = back ? _streak + 1 : 0;
      if (_streak >= policy.exitFixes) {
        _offRoute = false;
        _streak = 0;
      }
    } else {
      final away = distanceMeters > enter || wrongWay;
      _streak = away ? _streak + 1 : 0;
      if (_streak >= policy.enterFixes) {
        _offRoute = true;
        _streak = 0;
      }
    }
    return _offRoute;
  }
}
