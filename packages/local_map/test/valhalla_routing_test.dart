import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';

/// Antwortet auf jede Anfrage mit einer festen Valhalla-Antwort.
class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter(this.body);

  final Map<String, dynamic> body;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Die Anfrage im eigenen Valhalla-Format (ohne `format`), nicht die
/// zweite für die Spuren.
RequestOptions _nativeRequest(_FixedAdapter adapter) => adapter.requests
    .where((r) => (r.data as Map<String, dynamic>)['format'] == null)
    .single;

/// Kodiert Punkte als Polyline mit Genauigkeit 6, wie Valhalla sie liefert.
String _encode(List<List<double>> points) {
  final out = StringBuffer();
  var lastLat = 0;
  var lastLon = 0;
  void value(int v) {
    var x = v < 0 ? ~(v << 1) : v << 1;
    while (x >= 0x20) {
      out.writeCharCode((0x20 | (x & 0x1f)) + 63);
      x >>= 5;
    }
    out.writeCharCode(x + 63);
  }

  for (final p in points) {
    final lat = (p[0] * 1e6).round();
    final lon = (p[1] * 1e6).round();
    value(lat - lastLat);
    value(lon - lastLon);
    lastLat = lat;
    lastLon = lon;
  }
  return out.toString();
}

void main() {
  test(
    'Manoever-Indizes zeigen ueber alle Legs in die Gesamtgeometrie',
    () async {
      final leg1 = _encode([
        [50.0, 9.0],
        [50.001, 9.0],
        [50.002, 9.0],
      ]);
      final leg2 = _encode([
        [50.002, 9.0],
        [50.002, 9.001],
      ]);
      final dio = Dio()
        ..httpClientAdapter = _FixedAdapter({
          'trip': {
            'legs': [
              {
                'shape': leg1,
                'summary': {'length': 0.2, 'time': 30},
                'maneuvers': [
                  {
                    'instruction': 'Nach Norden fahren.',
                    'length': 0.2,
                    'time': 30,
                    'type': 1,
                    'begin_shape_index': 0,
                    'street_names': ['Hauptstraße'],
                  },
                ],
              },
              {
                'shape': leg2,
                'summary': {'length': 0.07, 'time': 10},
                'maneuvers': [
                  {
                    'instruction': 'Rechts abbiegen.',
                    'length': 0.07,
                    'time': 10,
                    'type': 10,
                    'begin_shape_index': 1,
                    'verbal_transition_alert_instruction': 'Rechts abbiegen.',
                    'verbal_pre_transition_instruction':
                        'Rechts abbiegen. Dann Ziel.',
                    'verbal_post_transition_instruction': ' ',
                  },
                ],
              },
            ],
          },
        });

      final RoutingProvider provider = ValhallaRoutingService(dio: dio);
      final result = await provider.route(
        start: const LatLng(50.0, 9.0),
        end: const LatLng(50.002, 9.001),
      );

      expect(result.geometry, hasLength(5));
      expect(result.distanceMeters, closeTo(270, 1e-6));
      expect(result.durationSeconds, 40);
      expect(result.maneuvers[0].beginShapeIndex, 0);
      expect(result.maneuvers[0].streetNames, ['Hauptstraße']);
      // Die erste Leg belegt die Indizes 0-2, Index 1 der zweiten Leg ist
      // damit Index 4 der Gesamtgeometrie.
      expect(result.maneuvers[1].beginShapeIndex, 4);
      expect(result.geometry[4].lon, closeTo(9.001, 1e-6));
      expect(result.maneuvers[1].streetNames, isEmpty);
      // Sprechtexte fuer Ansagen; leere zaehlen als fehlend.
      expect(result.maneuvers[1].verbalAlert, 'Rechts abbiegen.');
      expect(result.maneuvers[1].verbalPre, 'Rechts abbiegen. Dann Ziel.');
      expect(result.maneuvers[1].verbalPost, isNull);
      expect(result.maneuvers[0].verbalAlert, isNull);
    },
  );

  test(
    'routeAlongTrace schickt die Spur an /trace_route, ohne Doppelpunkte',
    () async {
      final adapter = _FixedAdapter({
        'trip': {
          'legs': [
            {
              'shape': _encode([
                [50.0, 9.0],
                [50.001, 9.0],
              ]),
              'summary': {'length': 0.1, 'time': 12},
              'maneuvers': <Object>[],
            },
          ],
        },
      });
      final service = ValhallaRoutingService(
        dio: Dio()..httpClientAdapter = adapter,
      );

      final result = await service.routeAlongTrace(const [
        LatLng(50.0, 9.0),
        LatLng(50.0, 9.0), // Stand an der Ampel
        LatLng(50.0, 9.0),
        LatLng(50.001, 9.0),
      ]);

      expect(result.geometry, hasLength(2));
      final request = _nativeRequest(adapter);
      expect(request.uri.path, '/trace_route');
      final body = request.data as Map<String, dynamic>;
      expect(body['shape'], hasLength(2));
      expect(body['shape_match'], 'map_snap');
      expect((body['directions_options'] as Map)['language'], 'de-DE');
    },
  );

  test('route fragt deutsche Anweisungen an', () async {
    final adapter = _FixedAdapter({
      'trip': {
        'legs': [
          {
            'shape': _encode([
              [50.0, 9.0],
              [50.001, 9.0],
            ]),
            'summary': {'length': 0.1, 'time': 12},
          },
        ],
      },
    });
    await ValhallaRoutingService(
      dio: Dio()..httpClientAdapter = adapter,
    ).route(start: const LatLng(50, 9), end: const LatLng(50.001, 9));
    final body = _nativeRequest(adapter).data as Map<String, dynamic>;
    expect(_nativeRequest(adapter).uri.path, '/route');
    expect((body['directions_options'] as Map)['language'], 'de-DE');
  });

  test('route gibt den Kurs als heading an den Startpunkt', () async {
    Future<Map<String, dynamic>> request(double? heading) async {
      final adapter = _FixedAdapter({
        'trip': {
          'legs': [
            {
              'shape': _encode([
                [50.0, 9.0],
                [50.001, 9.0],
              ]),
              'summary': {'length': 0.1, 'time': 12},
            },
          ],
        },
      });
      await ValhallaRoutingService(
        dio: Dio()..httpClientAdapter = adapter,
      ).route(
        start: const LatLng(50, 9),
        end: const LatLng(50.001, 9),
        startHeadingDegrees: heading,
      );
      final body = _nativeRequest(adapter).data as Map<String, dynamic>;
      return (body['locations'] as List).first as Map<String, dynamic>;
    }

    final withHeading = await request(-90.4);
    expect(withHeading['heading'], 270);
    expect(withHeading['heading_tolerance'], 45);

    expect((await request(null)).containsKey('heading'), isFalse);
    expect((await request(double.nan)).containsKey('heading'), isFalse);
  });

  group('Spuren', () {
    Map<String, dynamic> trip(List<Map<String, dynamic>> maneuvers) => {
      'trip': {
        'legs': [
          {
            'shape': _encode([
              [50.0, 9.0],
              [50.01, 9.0],
              [50.02, 9.0],
            ]),
            'summary': {'length': 2.2, 'time': 80},
            'maneuvers': maneuvers,
          },
        ],
      },
    };

    // Wie Valhalla 3.9 vor der Festhalle (Frankfurt, A 648): links nur
    // gültig, die zweite Spur ist die richtige.
    final fork = trip([
      {'instruction': 'Los', 'type': 1, 'begin_shape_index': 0},
      {
        'instruction': 'Leicht nach links',
        'type': 16,
        'begin_shape_index': 1,
        'lanes': [
          {'directions': 16, 'valid': 16},
          {'directions': 48, 'active': 16},
          {'directions': 32},
        ],
      },
      {'instruction': 'Ziel', 'type': 4, 'begin_shape_index': 2},
    ]);

    test('route fordert sie an und liest die Masken', () async {
      final adapter = _FixedAdapter(fork);
      final result = await ValhallaRoutingService(
        dio: Dio()..httpClientAdapter = adapter,
      ).route(start: const LatLng(50, 9), end: const LatLng(50.02, 9));

      expect(adapter.requests, hasLength(1));
      expect((adapter.requests.single.data as Map)['turn_lanes'], isTrue);

      expect(result.maneuvers[0].lanes, isEmpty);
      final lanes = result.maneuvers[1].lanes;
      expect(lanes.map((l) => l.indications), [
        ['slight left'],
        ['slight left', 'slight right'],
        ['slight right'],
      ]);
      expect(lanes.map((l) => l.valid), [true, true, false]);
      expect(lanes.map((l) => l.active), [false, true, false]);
      expect(lanes.map((l) => l.validIndication), [
        'slight left',
        'slight left',
        null,
      ]);
    });

    test('fetchLanes: false fordert sie nicht an', () async {
      final adapter = _FixedAdapter(fork);
      await ValhallaRoutingService(
        dio: Dio()..httpClientAdapter = adapter,
        fetchLanes: false,
      ).route(start: const LatLng(50, 9), end: const LatLng(50.02, 9));
      expect(
        (adapter.requests.single.data as Map).containsKey('turn_lanes'),
        isFalse,
      );
    });

    test('Map-Matching fordert sie ebenso an, joinRoutes behält sie', () async {
      final adapter = _FixedAdapter(fork);
      final result = await ValhallaRoutingService(
        dio: Dio()..httpClientAdapter = adapter,
      ).routeAlongTrace(const [LatLng(50, 9), LatLng(50.02, 9)]);
      expect(adapter.requests.single.uri.path, '/trace_route');
      expect((adapter.requests.single.data as Map)['turn_lanes'], isTrue);
      expect(result.maneuvers[1].lanes, hasLength(3));

      final joined = joinRoutes([result, result]);
      expect(joined.maneuvers.where((m) => m.lanes.isNotEmpty), hasLength(2));
    });

    test('Bitmasken auf Pfeile, von links nach rechts', () {
      expect(laneIndications(0), isEmpty);
      expect(laneIndications(1), ['none']);
      expect(laneIndications(2 | 64), ['straight', 'right']);
      expect(laneIndications(8 | 2), ['straight', 'left']);
      expect(laneIndications(256), ['uturn']);
      expect(laneIndications(512 | 1024), ['merge to left', 'merge to right']);
    });

    test('fromMasks: dieselbe Übersetzung für rohe Masken', () {
      // So reicht ein Backend die Spuren weiter, ohne Valhalla-JSON.
      final lane = RoutingLane.fromMasks(directions: 48, active: 16);
      expect(lane.indications, ['slight left', 'slight right']);
      expect(lane.valid, isTrue);
      expect(lane.active, isTrue);
      expect(lane.validIndication, 'slight left');

      final onlyValid = RoutingLane.fromMasks(directions: 16, valid: 16);
      expect(onlyValid.valid, isTrue);
      expect(onlyValid.active, isFalse);

      final wrong = RoutingLane.fromMasks(directions: 32);
      expect(wrong.valid, isFalse);
      expect(wrong.validIndication, isNull);
    });

    test('unbrauchbare Spuren fallen weg', () {
      expect(lanesFromValhalla(null), isEmpty);
      expect(lanesFromValhalla('kaputt'), isEmpty);
      final lanes = lanesFromValhalla([
        {'directions': 0},
        {'valid': 2},
        {'directions': 2, 'valid': 2, 'active': 2},
        {'directions': 10, 'valid': 10},
      ]);
      expect(lanes, hasLength(2));
      expect(lanes[0].active, isTrue);
      expect(lanes[0].validIndication, 'straight');
      // Zwei passende Pfeile: welcher, bleibt offen.
      expect(lanes[1].validIndication, isNull);
      expect(lanes[1].valid, isTrue);
    });
  });
}
