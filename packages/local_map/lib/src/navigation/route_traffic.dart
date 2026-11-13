import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../api/routing.dart';
import '../api/traffic.dart';
import '../services/autobahn_traffic_service.dart';

/// Wann und wie [LocalMapController] Verkehrsmeldungen holt.
class TrafficPolicy {
  /// `false`: keine Abrufe, auch wenn ein [TrafficProvider] gesetzt ist.
  final bool enabled;

  /// Abstand zwischen zwei Abrufen, solange eine Route besteht.
  final Duration refreshInterval;

  /// So weit darf ein Punkt einer Meldung von der Route entfernt liegen und
  /// noch zu ihr zählen. Die Linien der Quelle und die Route liegen auf
  /// verschiedenen Geometrien derselben Fahrbahn; 60 m fangen das auf.
  final double matchToleranceMeters;

  const TrafficPolicy({
    this.enabled = true,
    this.refreshInterval = const Duration(minutes: 5),
    this.matchToleranceMeters = 60,
  });
}

/// Wie schlimm ein Abschnitt ist - für die Farbe auf der Karte.
enum TrafficSeverity {
  /// Zähfließend, unter 5 min Verlust (gelb).
  light,

  /// Stau ab 5 min Verlust (orange).
  moderate,

  /// Ab 15 min Verlust oder Stillstand (rot).
  heavy,

  /// Gesperrt.
  closed,
}

/// Ein Stau oder eine Sperrung auf der Route.
class RouteTrafficSpan {
  final TrafficIncident incident;

  /// Beginn (das Stauende, auf das man zufährt) und Ende entlang der Route,
  /// in Metern ab Routenstart.
  final double startMeters;
  final double endMeters;

  /// Das Stück der Routengeometrie zwischen [startMeters] und [endMeters],
  /// zum Einfärben.
  final List<LatLng> points;

  final TrafficSeverity severity;

  /// Zeitverlust, den dieser Abschnitt auf der Route kostet: der gemeldete
  /// Wert, anteilig, wenn die Route nur einen Teil des Staus fährt. 0 ohne
  /// Angabe der Quelle - geschätzt wird nicht.
  final int delaySeconds;

  const RouteTrafficSpan({
    required this.incident,
    required this.startMeters,
    required this.endMeters,
    required this.points,
    required this.severity,
    required this.delaySeconds,
  });

  double get lengthMeters => endMeters - startMeters;

  /// Verlust ab [traveledMeters]: ganz, solange der Abschnitt vor einem
  /// liegt, anteilig mittendrin, 0 dahinter.
  int delayAheadSeconds(double traveledMeters) {
    if (delaySeconds == 0 || traveledMeters >= endMeters) return 0;
    if (traveledMeters <= startMeters || lengthMeters <= 0) {
      return delaySeconds;
    }
    return (delaySeconds * (endMeters - traveledMeters) / lengthMeters).round();
  }
}

/// Eine Meldung ohne Richtung (Baustelle, Warnung, gesperrte Ausfahrt)
/// nahe der Route. Sie kann ebenso die Gegenfahrbahn betreffen.
class RouteTrafficNotice {
  final TrafficIncident incident;

  /// Wo [TrafficIncident.position] auf die Route fällt, in Metern ab
  /// Routenstart.
  final double atMeters;

  const RouteTrafficNotice({required this.incident, required this.atMeters});
}

/// Die Verkehrslage entlang einer Route.
class RouteTraffic {
  /// Staus und Sperrungen in Fahrtrichtung, nach [RouteTrafficSpan.startMeters]
  /// sortiert.
  final List<RouteTrafficSpan> spans;

  /// Meldungen ohne Richtung nahe der Route, nach Lage sortiert.
  final List<RouteTrafficNotice> notices;

  /// Der Abruf, aus dem die Lage stammt - mit dem Stand je Straße.
  final TrafficReport report;

  const RouteTraffic({
    required this.spans,
    required this.notices,
    required this.report,
  });

  static const RouteTraffic empty = RouteTraffic(
    spans: <RouteTrafficSpan>[],
    notices: <RouteTrafficNotice>[],
    report: TrafficReport.empty,
  );

  /// Ordnet die Meldungen aus [report] der [route] zu.
  ///
  /// Ein Stau zählt nur, wenn seine Linie entlang der Route in derselben
  /// Richtung verläuft: Die Gegenfahrbahn liegt oft keine 30 m daneben,
  /// ihre Staus laufen aber rückwärts. Eine Route, die mitten im Stau
  /// auffährt oder abfährt, bekommt den Teil, den sie fährt.
  factory RouteTraffic.match(
    RoutingResult route,
    TrafficReport report, {
    double toleranceMeters = 60,
  }) {
    final line = _RouteLine(route.geometry.map((p) => p.toLatLng()).toList());
    if (line.points.length < 2) {
      return RouteTraffic(spans: const [], notices: const [], report: report);
    }

    final spans = <RouteTrafficSpan>[];
    final notices = <RouteTrafficNotice>[];
    for (final incident in report.incidents) {
      if (incident.isDirectional && incident.line.length >= 2) {
        final span = _matchSpan(line, incident, toleranceMeters);
        if (span != null) spans.add(span);
        continue;
      }
      final position = incident.position;
      if (position == null ||
          !line.bounds(toleranceMeters).contains(position)) {
        continue;
      }
      final hit = line.project(position);
      if (hit.distance <= toleranceMeters) {
        notices.add(
          RouteTrafficNotice(incident: incident, atMeters: hit.along),
        );
      }
    }
    notices.sort((a, b) => a.atMeters.compareTo(b.atMeters));
    return RouteTraffic(
      spans: _withoutDuplicates(spans),
      notices: notices,
      report: report,
    );
  }

  /// Zwei Quellen ([CombinedTrafficProvider]) melden oft denselben Stau,
  /// eine Quelle allein manchmal Stau und Sperrung an derselben Stelle.
  /// Doppelt gezählt wäre auch der Zeitverlust doppelt. Decken sich zwei
  /// Abschnitte zu mehr als der Hälfte des kürzeren, bleibt der schwerere:
  /// Sperrung vor Stau, dann mehr Verlust, dann der längere.
  static List<RouteTrafficSpan> _withoutDuplicates(
    List<RouteTrafficSpan> spans,
  ) {
    final kept = <RouteTrafficSpan>[];
    for (final span in spans) {
      final i = kept.indexWhere((k) {
        final overlap =
            math.min(k.endMeters, span.endMeters) -
            math.max(k.startMeters, span.startMeters);
        return overlap > 0.5 * math.min(k.lengthMeters, span.lengthMeters);
      });
      if (i < 0) {
        kept.add(span);
      } else if (_heavier(span, kept[i])) {
        kept[i] = span;
      }
    }
    kept.sort((a, b) => a.startMeters.compareTo(b.startMeters));
    return kept;
  }

  static bool _heavier(RouteTrafficSpan a, RouteTrafficSpan b) {
    if (a.severity != b.severity) return a.severity.index > b.severity.index;
    if (a.delaySeconds != b.delaySeconds) {
      return a.delaySeconds > b.delaySeconds;
    }
    return a.lengthMeters > b.lengthMeters;
  }

  static RouteTrafficSpan? _matchSpan(
    _RouteLine line,
    TrafficIncident incident,
    double tolerance,
  ) {
    final box = line.bounds(tolerance);
    if (!incident.line.any(box.contains)) return null;

    // Die Punkte der Meldung, die auf der Route liegen, mit ihrer Lage.
    final along = <double>[];
    var lastHit = -1;
    for (var i = 0; i < incident.line.length; i++) {
      final p = incident.line[i];
      if (!box.contains(p)) continue;
      final hit = line.project(p);
      if (hit.distance > tolerance) continue;
      // Eine Lücke heißt: die Route verlässt die Strecke dazwischen. Dann
      // gilt nur der erste zusammenhängende Teil.
      if (lastHit >= 0 && i != lastHit + 1) break;
      along.add(hit.along);
      lastHit = i;
    }
    if (along.length < 2) return null;

    // In Fahrtrichtung: jeder Punkt weiter vorn als der vorige, mit etwas
    // Spiel für die verschiedenen Geometrien.
    for (var i = 1; i < along.length; i++) {
      if (along[i] < along[i - 1] - _backwardSlackMeters) return null;
    }
    final start = along.first;
    final end = along.last;
    if (end - start < _minSpanMeters) return null;

    final incidentLength = incident.lengthMeters;
    final share = incidentLength <= 0
        ? 1.0
        : math.min(1.0, (end - start) / incidentLength);
    final delay = incident.delayMinutes;

    return RouteTrafficSpan(
      incident: incident,
      startMeters: start,
      endMeters: end,
      points: line.slice(start, end),
      severity: severityOf(incident),
      // Fährt die Route fast den ganzen Stau, gilt der volle Wert - die
      // Geometrien sind nie ganz gleich lang.
      delaySeconds: delay == null
          ? 0
          : ((share > 0.9 ? 1.0 : share) * delay * 60).round(),
    );
  }

  static const double _backwardSlackMeters = 30;
  static const double _minSpanMeters = 50;

  /// Rot ab 15 min Verlust oder bei Stillstand, orange ab 5 min oder bei
  /// Stau, sonst gelb. Gesperrt geht vor.
  static TrafficSeverity severityOf(TrafficIncident incident) {
    if (incident.blocksRoad) return TrafficSeverity.closed;
    final delay = incident.delayMinutes ?? 0;
    if (delay >= 15 || incident.jamLevel == TrafficJamLevel.standstill) {
      return TrafficSeverity.heavy;
    }
    if (delay >= 5 || incident.jamLevel == TrafficJamLevel.queuing) {
      return TrafficSeverity.moderate;
    }
    return TrafficSeverity.light;
  }

  /// Zeitverlust durch Staus vor [traveledMeters], in Sekunden.
  int delayAheadSeconds(double traveledMeters) => spans.fold(
    0,
    (sum, span) => sum + span.delayAheadSeconds(traveledMeters),
  );

  /// Der nächste Abschnitt, der noch nicht hinter einem liegt.
  RouteTrafficSpan? nextSpan(double traveledMeters) {
    for (final span in spans) {
      if (span.endMeters > traveledMeters) return span;
    }
    return null;
  }

  /// Ob vor [traveledMeters] eine Vollsperrung liegt.
  bool closedAhead(double traveledMeters) => spans.any(
    (s) => s.severity == TrafficSeverity.closed && s.endMeters > traveledMeters,
  );
}

/// Die Autobahnen, über die [route] führt (`A3`, `A9`), in Fahrtreihenfolge.
/// Siehe [AutobahnTrafficService.roadsOn].
List<String> autobahnsOnRoute(RoutingResult route) =>
    AutobahnTrafficService.roadsOn(route);

/// Die Route als Linie mit aufsummierter Länge, zum Projizieren.
class _RouteLine {
  _RouteLine(this.points) : cumulative = List<double>.filled(points.length, 0) {
    for (var i = 1; i < points.length; i++) {
      cumulative[i] = cumulative[i - 1] + _distance(points[i - 1], points[i]);
    }
  }

  final List<LatLng> points;
  final List<double> cumulative;
  final Map<double, _Box> _boxes = {};

  _Box bounds(double margin) => _boxes.putIfAbsent(margin, () {
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in points) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLon = math.min(minLon, p.longitude);
      maxLon = math.max(maxLon, p.longitude);
    }
    final dLat = margin / _metersPerDeg;
    final dLon =
        margin /
        (_metersPerDeg * math.cos((minLat + maxLat) / 2 * math.pi / 180));
    return _Box(minLat - dLat, maxLat + dLat, minLon - dLon, maxLon + dLon);
  });

  /// Nächster Punkt der Route zu [p]: Lage entlang der Route und Abstand.
  ({double along, double distance}) project(LatLng p) {
    var bestDistance = double.infinity;
    var bestAlong = 0.0;
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i];
      final b = points[i + 1];
      final cosLat = math.cos(a.latitude * math.pi / 180);
      final bx = (b.longitude - a.longitude) * cosLat * _metersPerDeg;
      final by = (b.latitude - a.latitude) * _metersPerDeg;
      final px = (p.longitude - a.longitude) * cosLat * _metersPerDeg;
      final py = (p.latitude - a.latitude) * _metersPerDeg;
      final len2 = bx * bx + by * by;
      final t = len2 == 0 ? 0.0 : ((px * bx + py * by) / len2).clamp(0.0, 1.0);
      final dx = px - t * bx, dy = py - t * by;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d < bestDistance) {
        bestDistance = d;
        bestAlong = cumulative[i] + t * (cumulative[i + 1] - cumulative[i]);
      }
    }
    return (along: bestAlong, distance: bestDistance);
  }

  /// Die Punkte der Route zwischen [from] und [to] Metern, mit
  /// eingefügten Endpunkten.
  List<LatLng> slice(double from, double to) {
    final result = <LatLng>[_at(from)];
    for (var i = 0; i < points.length; i++) {
      if (cumulative[i] > from && cumulative[i] < to) result.add(points[i]);
    }
    result.add(_at(to));
    return result;
  }

  LatLng _at(double meters) {
    if (meters <= 0) return points.first;
    for (var i = 1; i < points.length; i++) {
      if (cumulative[i] >= meters) {
        final span = cumulative[i] - cumulative[i - 1];
        final t = span == 0 ? 0.0 : (meters - cumulative[i - 1]) / span;
        final a = points[i - 1], b = points[i];
        return LatLng(
          a.latitude + t * (b.latitude - a.latitude),
          a.longitude + t * (b.longitude - a.longitude),
        );
      }
    }
    return points.last;
  }
}

class _Box {
  final double minLat, maxLat, minLon, maxLon;

  const _Box(this.minLat, this.maxLat, this.minLon, this.maxLon);

  bool contains(LatLng p) =>
      p.latitude >= minLat &&
      p.latitude <= maxLat &&
      p.longitude >= minLon &&
      p.longitude <= maxLon;
}

const double _metersPerDeg = 111319.49;

double _distance(LatLng a, LatLng b) {
  final cosLat = math.cos((a.latitude + b.latitude) / 2 * math.pi / 180);
  final dx = (b.longitude - a.longitude) * cosLat * _metersPerDeg;
  final dy = (b.latitude - a.latitude) * _metersPerDeg;
  return math.sqrt(dx * dx + dy * dy);
}
