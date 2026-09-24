import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../api/routing.dart';

/// Wo die Position gerade auf der Route steht.
class RouteProgress {
  /// Kürzester Abstand der Position zur Route in Metern. Ein großer Wert
  /// heißt: das Fahrzeug hat die Route verlassen.
  final double distanceToRouteMeters;

  /// Der Punkt auf der Route, der der Position am nächsten liegt.
  final LatLng snappedPosition;

  /// Index des Routenabschnitts (von `geometry[i]` nach `geometry[i + 1]`),
  /// auf dem [snappedPosition] liegt.
  final int segmentIndex;

  /// Schon zurückgelegter Weg entlang der Route in Metern.
  final double traveledMeters;

  /// Restweg bis zum Ziel in Metern.
  final double remainingMeters;

  /// Restzeit bis zum Ziel. Die Gesamtzeit der Route anteilig nach dem
  /// Restweg - genauer wird es ohne Zeiten je Abschnitt nicht.
  final int remainingSeconds;

  /// Das nächste Manöver vor dem Fahrzeug, `null` hinter dem letzten.
  final RoutingManeuver? nextManeuver;

  /// Index von [nextManeuver] in [RoutingResult.maneuvers].
  final int? nextManeuverIndex;

  /// Weg bis zum Beginn von [nextManeuver] in Metern.
  final double? distanceToNextManeuverMeters;

  const RouteProgress({
    required this.distanceToRouteMeters,
    required this.snappedPosition,
    required this.segmentIndex,
    required this.traveledMeters,
    required this.remainingMeters,
    required this.remainingSeconds,
    required this.nextManeuver,
    required this.nextManeuverIndex,
    required this.distanceToNextManeuverMeters,
  });
}

/// Ordnet Positionen einer Route zu und merkt sich den letzten Abschnitt.
///
/// Gesucht wird zuerst in einem Fenster um den zuletzt gefundenen
/// Abschnitt. Das ist schnell und verhindert, dass eine Position an einer
/// Stelle, wo die Route sich selbst nahe kommt (Kehre, Hin- und Rückweg auf
/// derselben Straße), auf den falschen Teil springt. Nur wenn das Fenster
/// nichts Nahes findet, wird die ganze Route abgesucht.
class RouteTracker {
  RouteTracker(this.route)
    : _points = route.geometry
          .map((p) => p.toLatLng())
          .toList(growable: false) {
    _cumulative = List<double>.filled(_points.length, 0);
    for (var i = 1; i < _points.length; i++) {
      _cumulative[i] =
          _cumulative[i - 1] + _distanceMeters(_points[i - 1], _points[i]);
    }
  }

  final RoutingResult route;
  final List<LatLng> _points;
  late final List<double> _cumulative;
  int? _lastSegment;

  /// Abschnitte hinter bzw. vor dem letzten Treffer, die zuerst durchsucht
  /// werden. Vorwärts großzügiger: bei 1 Hz und Autobahntempo legt ein
  /// Fahrzeug zwischen zwei Meldungen mehrere kurze Abschnitte zurück.
  static const int _windowBack = 3;
  static const int _windowAhead = 80;

  /// Ab diesem Abstand zum Fenstertreffer wird die ganze Route abgesucht.
  static const double _rescanMeters = 50;

  /// Länge der Route entlang der Geometrie in Metern.
  double get lengthMeters => _cumulative.isEmpty ? 0 : _cumulative.last;

  /// Fortschritt für [position], `null` für eine Route ohne Abschnitte.
  RouteProgress? update(LatLng position) {
    if (_points.length < 2) {
      return null;
    }

    final segments = _points.length - 1;
    _Hit? hit;
    final last = _lastSegment;
    if (last != null) {
      hit = _nearest(
        position,
        math.max(0, last - _windowBack),
        math.min(segments - 1, last + _windowAhead),
      );
    }
    if (hit == null || hit.distance > _rescanMeters) {
      final full = _nearest(position, 0, segments - 1);
      if (hit == null || full.distance < hit.distance) {
        hit = full;
      }
    }
    _lastSegment = hit.segment;

    final traveled =
        _cumulative[hit.segment] +
        hit.t * (_cumulative[hit.segment + 1] - _cumulative[hit.segment]);
    final total = lengthMeters;
    final remaining = math.max(0.0, total - traveled);

    RoutingManeuver? next;
    int? nextIndex;
    double? toNext;
    final maneuvers = route.maneuvers;
    for (var i = 0; i < maneuvers.length; i++) {
      final begin = maneuvers[i].beginShapeIndex;
      if (begin == null || begin >= _points.length) continue;
      final at = _cumulative[begin];
      // Ein Manöver, dessen Punkt gerade erreicht ist, gilt noch als
      // "nächstes", bis er passiert ist.
      if (at >= traveled - 1) {
        next = maneuvers[i];
        nextIndex = i;
        toNext = math.max(0.0, at - traveled);
        break;
      }
    }

    return RouteProgress(
      distanceToRouteMeters: hit.distance,
      snappedPosition: hit.point,
      segmentIndex: hit.segment,
      traveledMeters: traveled,
      remainingMeters: remaining,
      remainingSeconds: total <= 0
          ? 0
          : (route.durationSeconds * remaining / total).round(),
      nextManeuver: next,
      nextManeuverIndex: nextIndex,
      distanceToNextManeuverMeters: toNext,
    );
  }

  _Hit _nearest(LatLng p, int from, int to) {
    _Hit? best;
    for (var i = from; i <= to; i++) {
      final hit = _project(p, i);
      if (best == null || hit.distance < best.distance) {
        best = hit;
      }
    }
    return best!;
  }

  /// Lotfußpunkt von [p] auf Abschnitt [i], in einer lokalen
  /// Plattkarten-Näherung um den Abschnittsanfang. Für Abschnitte von einigen
  /// hundert Metern ist der Fehler weit unter der GPS-Genauigkeit.
  _Hit _project(LatLng p, int i) {
    final a = _points[i];
    final b = _points[i + 1];
    final cosLat = math.cos(a.latitude * math.pi / 180);
    double x(LatLng q) => (q.longitude - a.longitude) * cosLat * _metersPerDeg;
    double y(LatLng q) => (q.latitude - a.latitude) * _metersPerDeg;

    final bx = x(b), by = y(b);
    final px = x(p), py = y(p);
    final len2 = bx * bx + by * by;
    var t = len2 == 0 ? 0.0 : (px * bx + py * by) / len2;
    t = t.clamp(0.0, 1.0);
    final dx = px - t * bx, dy = py - t * by;
    return _Hit(
      segment: i,
      t: t,
      distance: math.sqrt(dx * dx + dy * dy),
      point: LatLng(
        a.latitude + t * (b.latitude - a.latitude),
        a.longitude + t * (b.longitude - a.longitude),
      ),
    );
  }
}

class _Hit {
  final int segment;
  final double t;
  final double distance;
  final LatLng point;

  const _Hit({
    required this.segment,
    required this.t,
    required this.distance,
    required this.point,
  });
}

const double _metersPerDeg = 111319.49;

double _distanceMeters(LatLng a, LatLng b) {
  final cosLat = math.cos((a.latitude + b.latitude) / 2 * math.pi / 180);
  final dx = (b.longitude - a.longitude) * cosLat * _metersPerDeg;
  final dy = (b.latitude - a.latitude) * _metersPerDeg;
  return math.sqrt(dx * dx + dy * dy);
}
