import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_map/local_map.dart';

// Die Beispiele sind echten Antworten nachgebaut (MobiData BW, DATEX II
// v2, und NDW, DATEX II v3, beide vom 2026-11-15), gekürzt auf das, was
// der Dienst liest.

const _v2Head =
    '<d2LogicalModel xmlns="http://datex2.eu/schema/2/2_0" '
    'modelBaseVersion="2"><payloadPublication lang="de-DE" '
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
    'xsi:type="SituationPublication">'
    '<publicationTime>2026-11-15T10:26:44Z</publicationTime>';
const _v2Tail = '</payloadPublication></d2LogicalModel>';

/// Ein v2-Record mit Linie (gmlLineString `lon,lat`, dazu
/// linearByCoordinates wie bei MobiData BW).
String _v2Record({
  required String id,
  required String type,
  String extra = '',
  String comment = 'A5 Karlsruhe Richtung Basel\nzwischen A und B\n1 km Stau',
  List<List<double>> line = const [
    [47.62, 9.00],
    [47.61, 9.00],
    [47.60, 9.00],
  ],
  String validity = 'active',
  String start = '2026-11-15T09:00:00Z',
  String? end,
  bool bothDirections = false,
}) {
  final gml = line.map((p) => '${p[1]},${p[0]}').join(' ');
  return '<situationRecord id="$id" version="1" xsi:type="$type">'
      '<validity><validityStatus>$validity</validityStatus>'
      '<validityTimeSpecification><overallStartTime>$start</overallStartTime>'
      '${end == null ? '' : '<overallEndTime>$end</overallEndTime>'}'
      '</validityTimeSpecification></validity>'
      '<generalPublicComment><comment><values><value lang="de-DE">$comment'
      '</value></values></comment><commentType>description</commentType>'
      '</generalPublicComment>'
      '<groupOfLocations xsi:type="Linear"><locationForDisplay>'
      '<latitude>${line.first[0]}</latitude><longitude>${line.first[1]}'
      '</longitude></locationForDisplay>'
      '<networkLocationExtension><networkLocationExtended><bothDirections>'
      '$bothDirections</bothDirections></networkLocationExtended>'
      '</networkLocationExtension>'
      '<linearExtension><extendedLinear><linearByCoordinates>'
      '<start><latitude>${line.first[0]}</latitude><longitude>'
      '${line.first[1]}</longitude></start>'
      '<end><latitude>${line.last[0]}</latitude><longitude>${line.last[1]}'
      '</longitude></end></linearByCoordinates></extendedLinear>'
      '<linearLineStringExtension><gmlLineString><coordinates>$gml'
      '</coordinates></gmlLineString></linearLineStringExtension>'
      '</linearExtension></groupOfLocations>'
      '$extra</situationRecord>';
}

String _v2Situation(String id, List<String> records) =>
    '<situation id="$id" version="1">${records.join()}</situation>';

String _v2(List<String> situations) => '$_v2Head${situations.join()}$_v2Tail';

const _v3Head =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<mc:messageContainer xmlns:sit="http://datex2.eu/schema/3/situation" '
    'xmlns:mc="http://datex2.eu/schema/3/messageContainer" '
    'xmlns:loc="http://datex2.eu/schema/3/locationReferencing" '
    'xmlns:com="http://datex2.eu/schema/3/common" modelBaseVersion="3">'
    '<mc:payload xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
    'xsi:type="sit:SituationPublication" lang="nl" modelBaseVersion="3">';
const _v3Tail = '</mc:payload></mc:messageContainer>';

const _v3Closure =
    '<sit:situation id="NDW18_1_SIT">'
    '<sit:situationRecord xsi:type="sit:RoadOrCarriagewayOrLaneManagement" '
    'id="NDW18_1" version="1">'
    '<sit:validity><com:validityStatus>definedByValidityTimeSpec'
    '</com:validityStatus><com:validityTimeSpecification>'
    '<com:overallStartTime>2026-09-30T19:46:13Z</com:overallStartTime>'
    '<com:overallEndTime>2027-03-30T21:59:00Z</com:overallEndTime>'
    '</com:validityTimeSpecification></sit:validity>'
    '<sit:locationReference xsi:type="loc:ItineraryByIndexedLocations">'
    '<loc:locationContainedInItinerary index="0">'
    '<loc:location xsi:type="loc:LinearLocation">'
    '<loc:roadInformation><loc:roadNumber>N 342</loc:roadNumber>'
    '</loc:roadInformation>'
    '<loc:gmlLineString srsName="WGS 84"><loc:posList>52.230438 6.879891 '
    '52.231858 6.880314 52.232198 6.880608</loc:posList></loc:gmlLineString>'
    '</loc:location></loc:locationContainedInItinerary>'
    '</sit:locationReference>'
    '<sit:roadOrCarriagewayOrLaneManagementType>carriagewayClosures'
    '</sit:roadOrCarriagewayOrLaneManagementType>'
    '</sit:situationRecord></sit:situation>';

const _v3Accident =
    '<sit:situation id="NDW06_2">'
    '<sit:situationRecord xsi:type="sit:Accident" id="NDW06_2_1" version="1">'
    '<sit:validity><com:validityStatus>definedByValidityTimeSpec'
    '</com:validityStatus><com:validityTimeSpecification>'
    '<com:overallStartTime>2026-11-15T09:51:30.416645486Z'
    '</com:overallStartTime></com:validityTimeSpecification></sit:validity>'
    '<sit:locationReference xsi:type="loc:PointLocation">'
    '<loc:pointByCoordinates><loc:bearing>77</loc:bearing>'
    '<loc:pointCoordinates><loc:latitude>52.62809</loc:latitude>'
    '<loc:longitude>5.004323</loc:longitude></loc:pointCoordinates>'
    '</loc:pointByCoordinates></sit:locationReference>'
    '</sit:situationRecord></sit:situation>';

final _now = DateTime.utc(2026, 11, 15, 10, 40);

/// Gerade Route nach Süden auf 9,00° Ost, 47,63 bis 47,59 (rund 4,4 km).
RoutingResult _southRoute() => RoutingResult(
  geometry: [
    for (var i = 0; i <= 8; i++) RoutingPoint(lat: 47.63 - i * 0.005, lon: 9.0),
  ],
  distanceMeters: 4450,
  durationSeconds: 200,
  maneuvers: const [],
);

void main() {
  group('Datex2TrafficService.parse – v2', () {
    test('Stau mit Linie in Fahrtrichtung, Straße, Richtung, Verlust', () {
      final list = Datex2TrafficService.parse(
        _v2([
          _v2Situation('S1', [
            _v2Record(
              id: 'S1.0',
              type: 'AbnormalTraffic',
              extra:
                  '<impact><delays><delayTimeValue>600.0</delayTimeValue>'
                  '</delays></impact>'
                  '<abnormalTrafficType>stationaryTraffic'
                  '</abnormalTrafficType>',
            ),
          ]),
        ]),
        now: _now,
      );
      expect(list, hasLength(1));
      final jam = list.single;
      expect(jam.id, 'S1');
      expect(jam.kind, TrafficIncidentKind.jam);
      expect(jam.jamLevel, TrafficJamLevel.standstill);
      expect(jam.road, 'A5');
      expect(jam.direction, 'Basel');
      expect(jam.title, 'A5 Karlsruhe Richtung Basel');
      expect(jam.delayMinutes, 10);
      expect(jam.isDirectional, isTrue);
      // gml ist lon,lat - der erste Punkt bleibt der Anfang (Norden).
      expect(jam.line.first.latitude, closeTo(47.62, 1e-9));
      expect(jam.line.first.longitude, closeTo(9.00, 1e-9));
      expect(jam.line.last.latitude, closeTo(47.60, 1e-9));
    });

    test('Situation in beiden Richtungen: je Richtung eine Meldung, die '
        'schwerste Art gewinnt', () {
      const there = [
        [48.7385, 9.1068],
        [48.7300, 9.1068],
      ];
      const back = [
        [48.7300, 9.1068],
        [48.7385, 9.1068],
      ];
      String closure(String id, List<List<double>> l) => _v2Record(
        id: id,
        type: 'RoadOrCarriagewayOrLaneManagement',
        line: l,
        comment:
            'Stuttgart, Robert-Leicht-Straße\nin beiden Richtungen '
            'gesperrt',
        extra:
            '<roadOrCarriagewayOrLaneManagementType>roadClosed'
            '</roadOrCarriagewayOrLaneManagementType>',
      );
      String works(String id, List<List<double>> l) => _v2Record(
        id: id,
        type: 'MaintenanceWorks',
        line: l,
        comment: 'Stuttgart, Robert-Leicht-Straße',
        extra: '<roadMaintenanceType>roadworks</roadMaintenanceType>',
      );
      // AbnormalTraffic ohne Art ist nur die Folge der Baustelle.
      String follow(String id, List<List<double>> l) =>
          _v2Record(id: id, type: 'AbnormalTraffic', line: l);

      final list = Datex2TrafficService.parse(
        _v2([
          _v2Situation('S2', [
            works('a', there),
            closure('b', there),
            follow('c', there),
            closure('d', back),
            works('e', back),
          ]),
        ]),
        now: _now,
      );
      expect(list.map((i) => i.id), ['S2#0', 'S2#1']);
      for (final i in list) {
        expect(i.kind, TrafficIncidentKind.closure);
        expect(i.blocksRoad, isTrue);
        expect(i.isDirectional, isTrue);
        expect(i.road, '');
        expect(i.title, 'Stuttgart, Robert-Leicht-Straße');
      }
      expect(
        list[0].line.first.latitude,
        isNot(closeTo(list[1].line.first.latitude, 1e-6)),
      );
    });

    test('Baustelle ist nicht gerichtet, Fahrstreifensperrung sperrt '
        'nicht', () {
      final list = Datex2TrafficService.parse(
        _v2([
          _v2Situation('W', [
            _v2Record(
              id: 'W.0',
              type: 'MaintenanceWorks',
              extra: '<roadMaintenanceType>roadworks</roadMaintenanceType>',
            ),
          ]),
          _v2Situation('L', [
            _v2Record(
              id: 'L.0',
              type: 'RoadOrCarriagewayOrLaneManagement',
              line: const [
                [48.0, 8.0],
                [48.01, 8.0],
              ],
              extra:
                  '<roadOrCarriagewayOrLaneManagementType>laneClosures'
                  '</roadOrCarriagewayOrLaneManagementType>',
            ),
          ]),
        ]),
        now: _now,
      );
      expect(list, hasLength(2));
      expect(list[0].kind, TrafficIncidentKind.roadworks);
      expect(list[0].isDirectional, isFalse);
      expect(list[1].kind, TrafficIncidentKind.closure);
      expect(list[1].blocksRoad, isFalse);
      expect(list[1].isDirectional, isFalse);
    });

    test('beidseitig gemeldete Linie ist nicht gerichtet', () {
      final list = Datex2TrafficService.parse(
        _v2([
          _v2Situation('B', [
            _v2Record(
              id: 'B.0',
              type: 'AbnormalTraffic',
              bothDirections: true,
              extra: '<abnormalTrafficType>slowTraffic</abnormalTrafficType>',
            ),
          ]),
        ]),
        now: _now,
      );
      expect(list.single.kind, TrafficIncidentKind.jam);
      expect(list.single.isDirectional, isFalse);
    });

    test('ausgesetzt, abgelaufen und angekündigt fallen weg', () {
      String jam(
        String id, {
        String validity = 'definedByValidityTimeSpec',
        String start = '2026-11-15T09:00:00Z',
        String? end,
      }) => _v2Situation(id, [
        _v2Record(
          id: '$id.0',
          type: 'AbnormalTraffic',
          validity: validity,
          start: start,
          end: end,
          extra: '<abnormalTrafficType>queuingTraffic</abnormalTrafficType>',
        ),
      ]);
      final xml = _v2([
        jam('suspended', validity: 'suspended'),
        jam('ended', end: '2026-11-15T10:00:00Z'),
        jam('planned', start: '2026-11-16T06:00:00Z'),
        jam('now', end: '2026-11-15T12:00:00Z'),
      ]);
      expect(Datex2TrafficService.parse(xml, now: _now).map((i) => i.id), [
        'now',
      ]);
      expect(
        Datex2TrafficService.parse(
          xml,
          now: _now,
          includePlanned: true,
        ).map((i) => i.id),
        ['planned', 'now'],
      );
    });

    test('nur ALERT-C ohne Koordinaten fällt weg', () {
      const xml =
          '$_v2Head<situation id="X"><situationRecord id="X.0" '
          'xsi:type="AbnormalTraffic"><validity><validityStatus>active'
          '</validityStatus></validity><groupOfLocations '
          'xsi:type="Linear"><alertCLinear><alertCLocationCountryCode>D'
          '</alertCLocationCountryCode></alertCLinear></groupOfLocations>'
          '<abnormalTrafficType>stationaryTraffic</abnormalTrafficType>'
          '</situationRecord></situation>$_v2Tail';
      expect(Datex2TrafficService.parse(xml, now: _now), isEmpty);
    });

    test('Umleitung allein ergibt keine Meldung', () {
      final list = Datex2TrafficService.parse(
        _v2([
          _v2Situation('R', [
            _v2Record(id: 'R.0', type: 'ReroutingManagement'),
          ]),
        ]),
        now: _now,
      );
      expect(list, isEmpty);
    });
  });

  group('Datex2TrafficService.parse – v3', () {
    test('Sperrung mit posList (lat lon) und Straßennummer', () {
      final list = Datex2TrafficService.parse(
        '$_v3Head$_v3Closure$_v3Tail',
        now: _now,
      );
      final c = list.single;
      expect(c.id, 'NDW18_1_SIT');
      expect(c.kind, TrafficIncidentKind.closure);
      expect(c.blocksRoad, isTrue);
      expect(c.isDirectional, isTrue);
      expect(c.road, 'N342');
      expect(c.title, 'Sperrung');
      expect(c.line.first.latitude, closeTo(52.230438, 1e-9));
      expect(c.line.first.longitude, closeTo(6.879891, 1e-9));
      expect(c.position, c.line.first);
    });

    test('Unfall als Punkt: Warnung ohne Linie', () {
      final w = Datex2TrafficService.parse(
        '$_v3Head$_v3Accident$_v3Tail',
        now: _now,
      ).single;
      expect(w.kind, TrafficIncidentKind.warning);
      expect(w.line, isEmpty);
      expect(w.isDirectional, isFalse);
      expect(w.position!.latitude, closeTo(52.62809, 1e-9));
      expect(w.since, DateTime.parse('2026-11-15T09:51:30.416645486Z'));
    });

    test('im SOAP-Umschlag', () {
      final soap =
          "<soapenv:Envelope xmlns:soapenv='http://schemas.xmlsoap.org/soap/"
          "envelope/'><soapenv:Body>"
          '${'$_v3Head$_v3Closure$_v3Accident$_v3Tail'.replaceFirst('<?xml version="1.0" encoding="UTF-8"?>', '')}'
          '</soapenv:Body></soapenv:Envelope>';
      expect(Datex2TrafficService.parse(soap, now: _now), hasLength(2));
    });
  });

  group('Datex2TrafficService.filterNear', () {
    TrafficIncident at(String id, double lat, double lon) => TrafficIncident(
      id: id,
      kind: TrafficIncidentKind.warning,
      road: '',
      title: id,
      position: LatLng(lat, lon),
    );

    test('behält Meldungen im Korridor, verwirft ferne', () {
      final kept = Datex2TrafficService.filterNear(
        [
          at('on', 47.61, 9.0),
          // ~750 m östlich
          at('near', 47.61, 9.01),
          // ~7,5 km östlich
          at('far', 47.61, 9.1),
          // weit nördlich, außerhalb des Rechtecks
          at('north', 48.5, 9.0),
        ],
        _southRoute(),
        2000,
      );
      expect(kept.map((i) => i.id), ['on', 'near']);
    });
  });

  group('Datex2TrafficService – Abruf', () {
    final body = _v2([
      _v2Situation('S1', [
        _v2Record(
          id: 'S1.0',
          type: 'AbnormalTraffic',
          extra: '<abnormalTrafficType>queuingTraffic</abnormalTrafficType>',
        ),
      ]),
    ]);

    test(
      'holt, ordnet zu, hält frisch und fragt mit If-Modified-Since',
      () async {
        var now = _now;
        final requests = <http.Request>[];
        var status = 200;
        final client = MockClient((request) async {
          requests.add(request);
          if (status != 200) return http.Response('', status);
          return http.Response.bytes(
            utf8.encode(body),
            200,
            headers: {'last-modified': 'Sun, 15 Nov 2026 10:26:44 GMT'},
          );
        });
        final service = Datex2TrafficService(
          uri: Uri.parse('https://example.org/d2.xml'),
          name: 'Test',
          client: client,
          clock: () => now,
        );

        var report = await service.incidentsAlong(_southRoute());
        expect(report.incidents.single.id, 'S1');
        expect(report.sources.single.name, 'Test');
        expect(report.sources.single.state, TrafficDataState.fresh);
        expect(requests.single.headers['accept-encoding'], 'gzip');
        expect(
          requests.single.headers.containsKey('if-modified-since'),
          isFalse,
        );

        // Innerhalb von freshFor keine neue Anfrage.
        now = now.add(const Duration(minutes: 1));
        await service.incidentsAlong(_southRoute());
        expect(requests, hasLength(1));

        // Danach 304: alter Stand gilt als frisch.
        now = now.add(const Duration(minutes: 2));
        status = 304;
        report = await service.incidentsAlong(_southRoute());
        expect(requests, hasLength(2));
        expect(
          requests.last.headers['if-modified-since'],
          'Sun, 15 Nov 2026 10:26:44 GMT',
        );
        expect(report.incidents.single.id, 'S1');
        expect(report.sources.single.state, TrafficDataState.fresh);

        // Fehler: alter Stand als Ersatz.
        now = now.add(const Duration(minutes: 3));
        status = 500;
        report = await service.incidentsAlong(_southRoute());
        expect(report.incidents.single.id, 'S1');
        expect(report.sources.single.state, TrafficDataState.cached);
        expect(report.sources.single.error, contains('500'));

        // Zu alt: kein Ersatz mehr.
        now = now.add(const Duration(hours: 7));
        report = await service.incidentsAlong(_southRoute());
        expect(report.incidents, isEmpty);
        expect(report.sources.single.state, TrafficDataState.failed);
      },
    );

    test('204 ohne eigenen Stand ist kein "frei"', () async {
      final service = Datex2TrafficService(
        uri: Uri.parse('https://example.org/d2.xml'),
        client: MockClient((_) async => http.Response('', 204)),
        clock: () => _now,
      );
      final report = await service.incidents();
      expect(report.sources.single.state, TrafficDataState.failed);
    });

    test('gzip-Körper, den der Client nicht auspackt', () async {
      final service = Datex2TrafficService(
        uri: Uri.parse('https://example.org/d2.xml.gz'),
        client: MockClient(
          (_) async => http.Response.bytes(gzip.encode(utf8.encode(body)), 200),
        ),
        clock: () => _now,
      );
      final report = await service.incidents();
      expect(report.incidents.single.id, 'S1');
    });

    test('der Stau landet über RouteTraffic.match auf der Route', () async {
      final service = Datex2TrafficService(
        uri: Uri.parse('https://example.org/d2.xml'),
        client: MockClient((_) async => http.Response(body, 200)),
        clock: () => _now,
      );
      final route = _southRoute();
      final traffic = RouteTraffic.match(
        route,
        await service.incidentsAlong(route),
      );
      expect(traffic.spans, hasLength(1));
      expect(traffic.spans.single.severity, TrafficSeverity.moderate);
      expect(traffic.spans.single.startMeters, closeTo(1112, 60));
    });

    test('Adressen der Mobilithek', () {
      expect(
        Datex2TrafficService.mobilithekV2('2000000').toString(),
        'https://mobilithek.info:8443/mobilithek/api/v1.0/subscription/'
        '2000000/clientPullService?subscriptionID=2000000',
      );
      expect(
        Datex2TrafficService.mobilithekV3('2000000').toString(),
        'https://mobilithek.info:8443/mobilithek/api/v1.0/subscription/'
        'datexv3?subscriptionID=2000000',
      );
    });
  });
}
