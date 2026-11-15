import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_map/local_map.dart';

/// Eine Linie entlang des 50. Breitengrads von [fromLon] nach [toLon] in
/// Schritten von 0,002 Grad (rund 143 m), als GeoJSON wie bei der
/// Autobahn GmbH: `[lon, lat]`.
Map<String, Object?> _geo(double fromLon, double toLon, {double lat = 50}) {
  final step = fromLon < toLon ? 0.002 : -0.002;
  final coords = <List<double>>[];
  for (
    var lon = fromLon;
    step > 0 ? lon <= toLon + 1e-9 : lon >= toLon - 1e-9;
    lon += step
  ) {
    coords.add([lon, lat]);
  }
  return {'type': 'LineString', 'coordinates': coords};
}

/// Ein Eintrag aus `warning`, aufgebaut wie eine echte Antwort (A3,
/// 2026-11-13): Zahlen als Text, Koordinate mit `long`, Beschreibung als
/// Zeilenliste.
Map<String, Object?> _jamEntry({
  String id = 'jam-1',
  double fromLon = 9.03,
  double toLon = 9.05,
  double lat = 50,
  String delay = '9',
  String type = 'SLOW_TRAFFIC',
  bool future = false,
  List<String> description = const ['Stockender Verkehr'],
}) => {
  'identifier': id,
  'isBlocked': 'false',
  'future': future,
  'display_type': 'WARNING',
  'subtitle': ' Nürnberg -> Passau',
  'title': 'A3 | Laaber - Erlgrund',
  'startTimestamp': '2026-11-13T08:40:00Z',
  'delayTimeValue': delay,
  'abnormalTrafficType': type,
  'averageSpeed': '25',
  'coordinate': {'lat': lat, 'long': fromLon},
  'description': description,
  'geometry': _geo(fromLon, toLon, lat: lat),
};

/// Gerade Route nach Osten auf dem 50. Breitengrad, 9,00 bis 9,10 Grad
/// (rund 7,2 km), über die A3.
RoutingResult _route() => RoutingResult(
  geometry: [
    for (var i = 0; i <= 10; i++) RoutingPoint(lat: 50, lon: 9 + i * 0.01),
  ],
  distanceMeters: 7160,
  durationSeconds: 300,
  maneuvers: const [
    RoutingManeuver(
      instruction: 'Auf A 3 auffahren',
      lengthKm: 7.16,
      timeSeconds: 300,
      type: 1,
      beginShapeIndex: 0,
      streetNames: ['A 3', 'E 56'],
    ),
  ],
);

TrafficIncident _incident(
  Map<String, Object?> entry, {
  String service = 'warning',
}) => AutobahnTrafficService.parseResponse(
  {
    service: [entry],
  },
  road: 'A3',
  service: service,
).single;

TrafficReport _report(List<TrafficIncident> incidents) => TrafficReport(
  incidents: incidents,
  sources: const [
    TrafficSourceStatus(name: 'A3', state: TrafficDataState.fresh),
  ],
);

void main() {
  group('AutobahnTrafficService.normalizeRoad', () {
    test('liest die Schreibweisen aus OSM und der Schnittstelle', () {
      expect(AutobahnTrafficService.normalizeRoad('A 3'), 'A3');
      expect(AutobahnTrafficService.normalizeRoad('a99'), 'A99');
      expect(AutobahnTrafficService.normalizeRoad(' A 001 '), 'A1');
      expect(AutobahnTrafficService.normalizeRoad('BAB 7'), 'A7');
    });

    test('alles andere ist keine Autobahn', () {
      expect(AutobahnTrafficService.normalizeRoad('B 27'), isNull);
      expect(AutobahnTrafficService.normalizeRoad('E 56'), isNull);
      expect(AutobahnTrafficService.normalizeRoad('Amthof'), isNull);
      expect(AutobahnTrafficService.normalizeRoad('A 0'), isNull);
    });
  });

  group('AutobahnTrafficService.parseResponse', () {
    test('ein Stau mit Linie, Verlust und Richtung', () {
      final jam = _incident(_jamEntry());
      expect(jam.kind, TrafficIncidentKind.jam);
      expect(jam.id, 'jam-1');
      expect(jam.road, 'A3');
      expect(jam.direction, 'Nürnberg -> Passau');
      expect(jam.delayMinutes, 9);
      expect(jam.averageSpeedKmh, 25);
      expect(jam.jamLevel, TrafficJamLevel.slow);
      expect(jam.isDirectional, isTrue);
      expect(jam.blocksRoad, isFalse);
      expect(jam.position, const LatLng(50, 9.03));
      expect(jam.line.first, const LatLng(50, 9.03));
      expect(jam.line.last.longitude, closeTo(9.05, 1e-9));
      expect(jam.lengthMeters, closeTo(1433, 15));
      expect(jam.since, DateTime.utc(2026, 11, 13, 8, 40));
    });

    test('"im Stillstand" im Text geht vor dem Typ', () {
      final jam = _incident(
        _jamEntry(
          type: 'QUEUING_TRAFFIC',
          description: ['Stau, Verkehr im Stillstand'],
        ),
      );
      expect(jam.jamLevel, TrafficJamLevel.standstill);
    });

    test('angekündigte Meldungen fallen weg, außer auf Wunsch', () {
      final json = {
        'warning': [_jamEntry(future: true)],
      };
      expect(
        AutobahnTrafficService.parseResponse(
          json,
          road: 'A3',
          service: 'warning',
        ),
        isEmpty,
      );
      expect(
        AutobahnTrafficService.parseResponse(
          json,
          road: 'A3',
          service: 'warning',
          includePlanned: true,
        ),
        hasLength(1),
      );
    });

    test('Vollsperrung hat Richtung, gesperrte Ausfahrt nicht', () {
      final full = _incident({
        'identifier': 'c1',
        'display_type': 'CLOSURE',
        'isBlocked': 'false',
        'future': false,
        'title': 'A3 | Jura - Neumarkt-Ost',
        'coordinate': {'lat': '50', 'long': '9.03'},
        'geometry': _geo(9.03, 9.04),
      }, service: 'closure');
      expect(full.kind, TrafficIncidentKind.closure);
      expect(full.blocksRoad, isTrue);
      expect(full.isDirectional, isTrue);
      expect(full.delayMinutes, isNull);

      final ramp = _incident({
        'identifier': 'c2',
        'display_type': 'CLOSURE_ENTRY_EXIT',
        'future': false,
        'title': 'A3 | AS Laaber',
        'coordinate': {'lat': 50, 'long': 9.03},
      }, service: 'closure');
      expect(ramp.blocksRoad, isFalse);
      expect(ramp.isDirectional, isFalse);
    });

    test('Baustellen haben keine Richtung, Einträge ohne Titel fallen weg', () {
      final list = AutobahnTrafficService.parseResponse(
        {
          'roadworks': [
            {
              'identifier': 'r1',
              'display_type': 'ROADWORKS',
              'title': 'A3 | Baustelle',
              'coordinate': {'lat': 50, 'long': 9.05},
              'geometry': _geo(9.05, 9.06),
            },
            {'identifier': 'r2', 'title': ''},
            {
              'identifier': 'r3',
              'title': 'ohne Ort',
              'coordinate': {'lat': 0, 'long': 0},
            },
          ],
        },
        road: 'A3',
        service: 'roadworks',
      );
      expect(list.map((i) => i.id), ['r1', 'r3']);
      expect(list.first.kind, TrafficIncidentKind.roadworks);
      expect(list.first.isDirectional, isFalse);
      // 0/0 ist kein Ort.
      expect(list.last.position, isNull);
    });

    test('dünnt lange Linien aus, Anfang und Ende bleiben', () {
      final dense = {
        'type': 'LineString',
        'coordinates': [
          for (var i = 0; i <= 100; i++) [9 + i * 0.0001, 50.0],
        ],
      };
      final jam = _incident({..._jamEntry(), 'geometry': dense});
      // 100 Schritte zu rund 7 m: alle 40 m ein Punkt.
      expect(jam.line.length, lessThan(25));
      expect(jam.line.first, const LatLng(50, 9));
      expect(jam.line.last.longitude, closeTo(9.01, 1e-9));
    });
  });

  group('AutobahnTrafficService.incidents', () {
    test(
      'fragt je Straße drei Endpunkte, nacheinander, und speichert',
      () async {
        final asked = <String>[];
        var now = DateTime(2026, 11, 13, 10);
        final service = AutobahnTrafficService(
          clock: () => now,
          client: MockClient((request) async {
            asked.add(request.url.path);
            final name = request.url.pathSegments.last;
            final body = name == 'warning'
                ? {
                    'warning': [_jamEntry()],
                  }
                : {name: <Object>[]};
            return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
          }),
        );

        final report = await service.incidents(['A 3', 'A3', 'B 27']);
        expect(asked, [
          '/o/autobahn/A3/services/warning',
          '/o/autobahn/A3/services/closure',
          '/o/autobahn/A3/services/roadworks',
        ]);
        expect(report.incidents.single.direction, 'Nürnberg -> Passau');
        expect(report.sources.single.state, TrafficDataState.fresh);

        // Innerhalb von freshFor kein neuer Abruf.
        now = now.add(const Duration(minutes: 4));
        await service.incidents(['A3']);
        expect(asked, hasLength(3));

        now = now.add(const Duration(minutes: 2));
        await service.incidents(['A3']);
        expect(asked, hasLength(6));
      },
    );

    test('scheitert ein Endpunkt, gilt der alte Stand', () async {
      var now = DateTime(2026, 11, 13, 10);
      var failClosure = false;
      final service = AutobahnTrafficService(
        clock: () => now,
        client: MockClient((request) async {
          final name = request.url.pathSegments.last;
          if (failClosure && name == 'closure') {
            return http.Response('', 503);
          }
          final body = name == 'warning'
              ? {
                  'warning': [_jamEntry()],
                }
              : {name: <Object>[]};
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
        }),
      );

      await service.incidents(['A3']);
      failClosure = true;
      now = now.add(const Duration(minutes: 10));
      final report = await service.incidents(['A3']);
      expect(report.sources.single.state, TrafficDataState.cached);
      expect(report.sources.single.age, const Duration(minutes: 10));
      expect(report.sources.single.error, contains('503'));
      expect(report.incidents, hasLength(1));

      // Zu alt: keine Daten, und das steht auch so da.
      now = now.add(const Duration(hours: 7));
      final stale = await service.incidents(['A3']);
      expect(stale.sources.single.state, TrafficDataState.failed);
      expect(stale.failedSources, ['A3']);
      expect(stale.incidents, isEmpty);
    });

    test('Zeitüberschreitung wird zum Status, nicht zur Ausnahme', () async {
      final service = AutobahnTrafficService(
        timeout: const Duration(milliseconds: 10),
        client: MockClient((request) => Completer<http.Response>().future),
      );
      final report = await service.incidents(['A3']);
      expect(report.sources.single.state, TrafficDataState.failed);
      expect(report.sources.single.error, contains('keine Antwort'));
    });
  });

  group('RouteTraffic.match', () {
    test('ein Stau in Fahrtrichtung färbt sein Stück der Route', () {
      final traffic = RouteTraffic.match(
        _route(),
        _report([_incident(_jamEntry())]),
      );
      expect(traffic.spans, hasLength(1));
      final span = traffic.spans.single;
      expect(span.startMeters, closeTo(2150, 20));
      expect(span.endMeters, closeTo(3583, 20));
      expect(span.delaySeconds, 9 * 60);
      expect(span.severity, TrafficSeverity.moderate);
      expect(span.points.first.longitude, closeTo(9.03, 1e-6));
      expect(span.points.last.longitude, closeTo(9.05, 1e-6));
    });

    test('der Stau der Gegenfahrbahn zählt nicht', () {
      // 22 m daneben, aber nach Westen.
      final traffic = RouteTraffic.match(
        _route(),
        _report([
          _incident(_jamEntry(fromLon: 9.05, toLon: 9.03, lat: 50.0002)),
        ]),
      );
      expect(traffic.spans, isEmpty);
      expect(traffic.delayAheadSeconds(0), 0);
    });

    test('ein Stau auf einer anderen Straße zählt nicht', () {
      final traffic = RouteTraffic.match(
        _route(),
        _report([_incident(_jamEntry(lat: 50.01))]),
      );
      expect(traffic.spans, isEmpty);
    });

    test('fährt die Route nur einen Teil, zählt der Teil', () {
      // 8,98 bis 9,02, die Route beginnt bei 9,00: die Hälfte.
      final traffic = RouteTraffic.match(
        _route(),
        _report([
          _incident(_jamEntry(fromLon: 8.98, toLon: 9.02, delay: '10')),
        ]),
      );
      final span = traffic.spans.single;
      expect(span.startMeters, closeTo(0, 1));
      expect(span.delaySeconds, closeTo(300, 15));
    });

    test('Verlust voraus: ganz, anteilig, vorbei', () {
      final traffic = RouteTraffic.match(
        _route(),
        _report([_incident(_jamEntry(delay: '20'))]),
      );
      final span = traffic.spans.single;
      expect(traffic.delayAheadSeconds(0), 1200);
      final middle = (span.startMeters + span.endMeters) / 2;
      expect(traffic.delayAheadSeconds(middle), closeTo(600, 1));
      expect(traffic.delayAheadSeconds(span.endMeters + 1), 0);
      expect(traffic.nextSpan(0), same(span));
      expect(traffic.nextSpan(span.endMeters + 1), isNull);
      expect(span.severity, TrafficSeverity.heavy);
    });

    test('Baustellen ohne Richtung landen als Hinweis an der Route', () {
      final roadworks = AutobahnTrafficService.parseResponse(
        {
          'roadworks': [
            {
              'identifier': 'r1',
              'title': 'A3 | Baustelle',
              'coordinate': {'lat': 50.0003, 'long': 9.06},
            },
            {
              'identifier': 'r2',
              'title': 'A3 | weit weg',
              'coordinate': {'lat': 50.2, 'long': 9.06},
            },
          ],
        },
        road: 'A3',
        service: 'roadworks',
      );
      final traffic = RouteTraffic.match(_route(), _report(roadworks));
      expect(traffic.spans, isEmpty);
      expect(traffic.notices.single.incident.id, 'r1');
      expect(traffic.notices.single.atMeters, closeTo(4300, 20));
    });

    test('Schweregrad nach Verlust und Dichte', () {
      TrafficSeverity of({
        int? delay,
        TrafficJamLevel? level,
        bool blocks = false,
      }) => RouteTraffic.severityOf(
        TrafficIncident(
          id: 'x',
          kind: TrafficIncidentKind.jam,
          road: 'A3',
          title: 'x',
          delayMinutes: delay,
          jamLevel: level,
          blocksRoad: blocks,
        ),
      );
      expect(of(delay: 2, level: TrafficJamLevel.slow), TrafficSeverity.light);
      expect(of(delay: 5), TrafficSeverity.moderate);
      expect(of(level: TrafficJamLevel.queuing), TrafficSeverity.moderate);
      expect(of(delay: 15), TrafficSeverity.heavy);
      expect(of(level: TrafficJamLevel.standstill), TrafficSeverity.heavy);
      expect(of(delay: 30, blocks: true), TrafficSeverity.closed);
    });
  });

  test('autobahnsOnRoute liest die Nummern aus den Straßennamen', () {
    RoutingManeuver m(List<String> names) => RoutingManeuver(
      instruction: '',
      lengthKm: 1,
      timeSeconds: 60,
      type: 1,
      streetNames: names,
    );
    final route = RoutingResult(
      geometry: const [],
      distanceMeters: 0,
      durationSeconds: 0,
      maneuvers: [
        m(['Amthof']),
        m(['A 9', 'E 51']),
        m(['A 3;E 56']),
        m(['A 9']),
        m(['B 8']),
      ],
    );
    expect(autobahnsOnRoute(route), ['A9', 'A3']);
  });

  group('mehrere Quellen', () {
    test('derselbe Stau zweimal gemeldet zählt einmal, der schwerere', () {
      final traffic = RouteTraffic.match(
        _route(),
        _report([
          _incident(_jamEntry(id: 'a', delay: '12')),
          _incident(
            _jamEntry(id: 'b', fromLon: 9.032, toLon: 9.052, delay: '5'),
          ),
        ]),
      );
      expect(traffic.spans.single.incident.id, 'a');
      expect(traffic.delayAheadSeconds(0), 12 * 60);
    });

    test('getrennte Staus bleiben getrennt', () {
      final traffic = RouteTraffic.match(
        _route(),
        _report([
          _incident(_jamEntry(id: 'a', fromLon: 9.01, toLon: 9.03)),
          _incident(_jamEntry(id: 'b', fromLon: 9.06, toLon: 9.08)),
        ]),
      );
      expect(traffic.spans, hasLength(2));
    });

    test(
      'CombinedTrafficProvider legt zusammen, ein Fehler stört nicht',
      () async {
        final combined = CombinedTrafficProvider([
          _FakeTraffic([_incident(_jamEntry())]),
          _ThrowingTraffic(),
        ]);
        final report = await combined.incidentsAlong(_route());
        expect(report.incidents, hasLength(1));
        expect(report.sources.map((s) => s.state), [
          TrafficDataState.fresh,
          TrafficDataState.failed,
        ]);
        expect(report.failedSources, ['_ThrowingTraffic']);
      },
    );

    test('Autobahn GmbH: ohne Autobahn auf der Route keine Anfrage', () async {
      var asked = false;
      final service = AutobahnTrafficService(
        client: MockClient((request) async {
          asked = true;
          return http.Response('{}', 200);
        }),
      );
      final report = await service.incidentsAlong(
        RoutingResult(
          geometry: _route().geometry,
          distanceMeters: 7160,
          durationSeconds: 300,
          maneuvers: const [
            RoutingManeuver(
              instruction: '',
              lengthKm: 7.16,
              timeSeconds: 300,
              type: 1,
              streetNames: ['B 8'],
            ),
          ],
        ),
      );
      expect(asked, isFalse);
      expect(report.incidents, isEmpty);
      expect(report.sources, isEmpty);
    });
  });

  group('LocalMapController', () {
    test('holt den Verkehr zur Route und rechnet den Verlust', () async {
      final provider = _FakeTraffic([_incident(_jamEntry(delay: '12'))]);
      final controller = LocalMapController(trafficProvider: provider);
      addTearDown(controller.dispose);

      controller.setRoute(_route());
      expect(controller.routeTraffic, isNull);
      await pumpEventQueue();

      expect(provider.asked.single, ['A3']);
      expect(controller.isLoadingTraffic, isFalse);
      expect(controller.routeTraffic!.spans, hasLength(1));
      expect(controller.trafficDelaySeconds, 12 * 60);

      controller.setRoute(null);
      expect(controller.routeTraffic, isNull);
      expect(controller.trafficDelaySeconds, 0);
    });

    test('ohne Meldungen bleibt die Lage leer', () async {
      final provider = _FakeTraffic(const []);
      final controller = LocalMapController(trafficProvider: provider);
      addTearDown(controller.dispose);

      controller.setRoute(_route());
      await pumpEventQueue();
      expect(provider.asked, hasLength(1));
      expect(controller.routeTraffic!.spans, isEmpty);
      expect(controller.trafficDelaySeconds, 0);
    });

    test('abgeschaltet: kein Abruf', () async {
      final provider = _FakeTraffic(const []);
      final controller = LocalMapController(
        trafficProvider: provider,
        trafficPolicy: const TrafficPolicy(enabled: false),
      );
      addTearDown(controller.dispose);
      controller.setRoute(_route());
      await pumpEventQueue();
      expect(provider.asked, isEmpty);
      expect(controller.routeTraffic, isNull);
    });
  });
}

class _FakeTraffic implements TrafficProvider {
  _FakeTraffic(this.result);

  final List<TrafficIncident> result;

  /// Die Autobahnen jeder gefragten Route.
  final asked = <List<String>>[];

  @override
  Future<TrafficReport> incidentsAlong(RoutingResult route) async {
    final roads = autobahnsOnRoute(route);
    asked.add(roads);
    return TrafficReport(
      incidents: result,
      sources: [
        for (final r in roads)
          TrafficSourceStatus(name: r, state: TrafficDataState.fresh),
      ],
    );
  }
}

class _ThrowingTraffic implements TrafficProvider {
  @override
  Future<TrafficReport> incidentsAlong(RoutingResult route) async =>
      throw StateError('kaputt');
}
