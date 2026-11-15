import 'package:latlong2/latlong.dart';

import 'routing.dart';

/// Welche Art von Verkehrsmeldung.
enum TrafficIncidentKind {
  /// Stau oder stockender Verkehr, mit Länge und meist mit Zeitverlust.
  jam,

  /// Sperrung - ganz ([TrafficIncident.blocksRoad]) oder nur einer Auf-
  /// oder Abfahrt.
  closure,

  /// Baustelle.
  roadworks,

  /// Sonstige Warnung: Unfall, Gegenstand auf der Fahrbahn, Glätte.
  warning,
}

/// Wie dicht der Verkehr in einem Stau steht.
enum TrafficJamLevel {
  /// Stillstand.
  standstill,

  /// Stau, Schritttempo bis Stop-and-go.
  queuing,

  /// Stockender, zähfließender Verkehr.
  slow,

  /// Dichter Verkehr, noch fließend.
  heavy,

  /// Die Quelle sagt es nicht.
  unknown,
}

/// Eine Verkehrsmeldung, unabhängig von der Quelle.
class TrafficIncident {
  /// Kennung der Quelle. Bleibt über Abrufe gleich, solange die Meldung
  /// besteht.
  final String id;

  final TrafficIncidentKind kind;

  /// Die Straße, zu der die Meldung gehört, ohne Leerzeichen (`A3`, `B27`),
  /// leer, wenn die Quelle keine Nummer nennt.
  final String road;

  /// Kurztitel, etwa `A3 | Laaber - Erlgrund`.
  final String title;

  /// Fahrtrichtung in Worten (`Nürnberg -> Passau`), `null` ohne Angabe.
  final String? direction;

  /// Der ausführliche Text der Quelle, Zeilen durch `\n` getrennt.
  final String description;

  /// Wo die Meldung beginnt. `null`, wenn die Quelle keinen Ort nennt -
  /// dann kann sie nicht auf die Karte.
  final LatLng? position;

  /// Der betroffene Abschnitt, leer ohne Angabe. Bei [isDirectional] in
  /// Fahrtrichtung: der erste Punkt ist das Ende des Staus, auf das man
  /// zufährt.
  final List<LatLng> line;

  /// Ob [line] verlässlich in Fahrtrichtung liegt. Nur dann lässt sich die
  /// Meldung einer Richtungsfahrbahn der Route zuordnen; sonst trifft sie
  /// ebenso die Gegenrichtung.
  final bool isDirectional;

  /// Die Fahrbahn ist ganz gesperrt (nicht nur eine Auf- oder Abfahrt).
  final bool blocksRoad;

  /// Gemeldeter Zeitverlust in Minuten, `null` ohne Angabe. Nie geschätzt.
  final int? delayMinutes;

  /// Gemeldete Durchschnittsgeschwindigkeit im Stau, `null` ohne Angabe.
  final int? averageSpeedKmh;

  /// Nur bei [TrafficIncidentKind.jam].
  final TrafficJamLevel? jamLevel;

  /// Beginn der Meldung laut Quelle.
  final DateTime? since;

  const TrafficIncident({
    required this.id,
    required this.kind,
    required this.road,
    required this.title,
    this.direction,
    this.description = '',
    this.position,
    this.line = const <LatLng>[],
    this.isDirectional = false,
    this.blocksRoad = false,
    this.delayMinutes,
    this.averageSpeedKmh,
    this.jamLevel,
    this.since,
  });

  /// Länge von [line] in Metern, 0 ohne Linie.
  double get lengthMeters {
    var sum = 0.0;
    for (var i = 1; i < line.length; i++) {
      sum += const Distance().as(LengthUnit.Meter, line[i - 1], line[i]);
    }
    return sum;
  }
}

/// Wie verlässlich ein Teil eines Abrufs ist.
enum TrafficDataState {
  /// Gerade abgerufen oder jünger als die Frische-Grenze des Anbieters.
  fresh,

  /// Der Abruf ist gescheitert; es gilt ein älterer Stand.
  cached,

  /// Der Abruf ist gescheitert, und es gibt keinen brauchbaren Stand. Eine
  /// leere Liste heißt dann NICHT "frei".
  failed,
}

/// Stand eines Teils in einem [TrafficReport]: eine Autobahn (`A3`) bei
/// [AutobahnTrafficService]; ein Anbieter, der nach Gebiet fragt, nennt
/// hier seinen Ausschnitt.
class TrafficSourceStatus {
  /// Wofür der Stand gilt, zum Anzeigen und für Protokolle.
  final String name;
  final TrafficDataState state;

  /// Alter der Daten, `null` bei [TrafficDataState.failed].
  final Duration? age;

  /// Warum der Abruf scheiterte, `null` bei Erfolg.
  final String? error;

  const TrafficSourceStatus({
    required this.name,
    required this.state,
    this.age,
    this.error,
  });
}

/// Ergebnis eines Abrufs: die Meldungen und je Teil, wie verlässlich sie
/// sind.
class TrafficReport {
  final List<TrafficIncident> incidents;
  final List<TrafficSourceStatus> sources;

  const TrafficReport({required this.incidents, required this.sources});

  static const TrafficReport empty = TrafficReport(
    incidents: <TrafficIncident>[],
    sources: <TrafficSourceStatus>[],
  );

  /// Teile, für die es keine Daten gibt.
  Iterable<String> get failedSources => sources
      .where((s) => s.state == TrafficDataState.failed)
      .map((s) => s.name);

  /// Ob alle Teile frische Daten haben.
  bool get isFresh => sources.every((s) => s.state == TrafficDataState.fresh);
}

/// Liefert Verkehrsmeldungen entlang einer Route.
///
/// Wie bei [RoutingProvider] entscheidet der Gastgeber, woher sie kommen:
/// [AutobahnTrafficService] fragt die offene Schnittstelle der Autobahn
/// GmbH nach den Autobahnen der Route, [CombinedTrafficProvider] fragt
/// mehrere. Ein Fahrzeugsystem kann sein eigenes Backend fragen, auch nach
/// dem Gebiet, durch das die Route führt.
abstract interface class TrafficProvider {
  /// Meldungen, die [route] betreffen können. Wirft nicht: Fehler stehen
  /// je Teil in [TrafficReport.sources]. Welche Meldungen wirklich auf der
  /// Route liegen, entscheidet danach [RouteTraffic.match].
  Future<TrafficReport> incidentsAlong(RoutingResult route);
}

/// Fragt mehrere [TrafficProvider] gleichzeitig und legt die Ergebnisse
/// zusammen - etwa die Autobahn GmbH für Autobahnen und eine weitere
/// Quelle für den Rest. Doppelte Meldungen derselben Stelle bleiben im Bericht; beim
/// Zuordnen zur Route gilt je Abschnitt nur die schwerere
/// ([RouteTraffic.match]).
class CombinedTrafficProvider implements TrafficProvider {
  CombinedTrafficProvider(this.providers);

  final List<TrafficProvider> providers;

  @override
  Future<TrafficReport> incidentsAlong(RoutingResult route) async {
    final reports = await Future.wait([
      for (final provider in providers)
        provider
            .incidentsAlong(route)
            .catchError(
              (Object e) => TrafficReport(
                incidents: const [],
                sources: [
                  TrafficSourceStatus(
                    name: '${provider.runtimeType}',
                    state: TrafficDataState.failed,
                    error: '$e',
                  ),
                ],
              ),
            ),
    ]);
    return TrafficReport(
      incidents: [for (final r in reports) ...r.incidents],
      sources: [for (final r in reports) ...r.sources],
    );
  }
}
