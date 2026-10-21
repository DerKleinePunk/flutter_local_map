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

/// Antwortet im eigenen Format mit [native], auf `format: osrm` mit [osrm]
/// oder, ohne [osrm], mit HTTP 500.
class _TwoFormatAdapter implements HttpClientAdapter {
  _TwoFormatAdapter(this.native, [this.osrm]);

  final Map<String, dynamic> native;
  final Map<String, dynamic>? osrm;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final wantsOsrm =
        (options.data as Map<String, dynamic>)['format'] == 'osrm';
    final body = wantsOsrm ? osrm : native;
    return ResponseBody.fromString(
      body == null ? '{"error":"kaputt"}' : jsonEncode(body),
      body == null ? 500 : 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Eine Spur in OSRM-Schreibweise.
Map<String, dynamic> _lane(
  List<String> indications, {
  bool valid = false,
  bool active = false,
  String? validIndication,
}) => {
  'indications': indications,
  'valid': valid,
  'active': active,
  'valid_indication': ?validIndication,
};

/// Ein OSRM-Schritt am Ort [at] (`[lat, lon]`), mit Kreuzungen
/// `(Ort, Spuren)`; die erste Kreuzung liegt am Manöver.
Map<String, dynamic> _step(
  List<double> at,
  List<(List<double>, List<Map<String, dynamic>>?)> intersections,
) => {
  'maneuver': {
    'location': [at[1], at[0]],
  },
  'intersections': [
    for (final (where, lanes) in intersections)
      {
        'location': [where[1], where[0]],
        'lanes': ?lanes,
      },
  ],
};

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
    // Abfahrt, Gabelung 1,1 km weiter, Ziel noch 1,1 km weiter.
    const p0 = [50.0, 9.0], p1 = [50.01, 9.0], p2 = [50.02, 9.0];
    final native = {
      'trip': {
        'legs': [
          {
            'shape': _encode([p0, p1, p2]),
            'summary': {'length': 2.2, 'time': 80},
            'maneuvers': [
              {'instruction': 'Los', 'type': 1, 'begin_shape_index': 0},
              {
                'instruction': 'Links halten',
                'type': 23,
                'begin_shape_index': 1,
              },
              {'instruction': 'Ziel', 'type': 4, 'begin_shape_index': 2},
            ],
          },
        ],
      },
    };
    final fork = [
      _lane(['straight'], valid: true, active: true),
      _lane(
        ['straight', 'slight right'],
        valid: true,
        validIndication: 'straight',
      ),
      _lane(['slight right']),
    ];
    Map<String, dynamic> osrm(
      List<Map<String, dynamic>> steps, {
      String key = 'routes',
    }) => {
      key: [
        {
          'legs': [
            {'steps': steps},
          ],
        },
      ],
    };

    Future<(RoutingResult, _TwoFormatAdapter)> route(
      Map<String, dynamic>? osrmBody, {
      bool fetchLanes = true,
    }) async {
      final adapter = _TwoFormatAdapter(native, osrmBody);
      final result = await ValhallaRoutingService(
        dio: Dio()..httpClientAdapter = adapter,
        fetchLanes: fetchLanes,
      ).route(start: const LatLng(50, 9), end: const LatLng(50.02, 9));
      return (result, adapter);
    }

    test('kommen an das Manöver, an dessen Kreuzung sie stehen', () async {
      final (result, adapter) = await route(
        osrm([
          _step(p0, [(p0, null)]),
          _step(p1, [(p1, fork)]),
          _step(p2, [(p2, null)]),
        ]),
      );
      expect(adapter.requests, hasLength(2));
      final osrmBody = adapter.requests
          .map((r) => r.data as Map<String, dynamic>)
          .singleWhere((b) => b['format'] == 'osrm');
      expect(osrmBody['locations'], isNotNull);
      expect(osrmBody['costing'], 'auto');

      expect(result.maneuvers[0].lanes, isEmpty);
      expect(result.maneuvers[2].lanes, isEmpty);
      final lanes = result.maneuvers[1].lanes;
      expect(lanes.map((l) => l.indications), [
        ['straight'],
        ['straight', 'slight right'],
        ['slight right'],
      ]);
      expect(lanes.map((l) => l.valid), [true, true, false]);
      expect(lanes.map((l) => l.active), [true, false, false]);
      expect(lanes[1].validIndication, 'straight');
      expect(lanes[0].validIndication, isNull);
      // Die übrigen Angaben bleiben, wie sie waren.
      expect(result.maneuvers[1].instruction, 'Links halten');
      expect(result.maneuvers[1].beginShapeIndex, 1);
    });

    test('kurz vor der Kreuzung zählen sie, 1 km davor nicht mehr', () async {
      const shortlyBefore = [50.008, 9.0]; // 222 m vor p1
      var (result, _) = await route(
        osrm([
          _step(p0, [(p0, null), (shortlyBefore, fork)]),
          _step(p1, [(p1, null)]),
          _step(p2, [(p2, null)]),
        ]),
      );
      expect(result.maneuvers[1].lanes, hasLength(3));

      (result, _) = await route(
        osrm([
          // 1,1 km vor p1, kurz hinter dem Start.
          _step(p0, [
            (p0, null),
            ([50.0001, 9.0], fork),
          ]),
          _step(p1, [(p1, null)]),
          _step(p2, [(p2, null)]),
        ]),
      );
      expect(result.maneuvers.every((m) => m.lanes.isEmpty), isTrue);
    });

    test('ohne Antwort im OSRM-Format kommt die Route ohne Spuren', () async {
      final (result, _) = await route(null);
      expect(result.maneuvers, hasLength(3));
      expect(result.maneuvers.every((m) => m.lanes.isEmpty), isTrue);
    });

    test('passen Schritte und Manöver nicht zusammen, keine Spuren', () async {
      // Ein Schritt zu wenig.
      var (result, _) = await route(
        osrm([
          _step(p0, [(p0, null)]),
          _step(p1, [(p1, fork)]),
        ]),
      );
      expect(result.maneuvers.every((m) => m.lanes.isEmpty), isTrue);

      // Der Schritt liegt 1 km neben seinem Manöver.
      (result, _) = await route(
        osrm([
          _step(p0, [(p0, null)]),
          _step(p2, [(p2, fork)]),
          _step(p2, [(p2, null)]),
        ]),
      );
      expect(result.maneuvers[1].lanes, isEmpty);
    });

    test('fetchLanes: false fragt nur einmal', () async {
      final (result, adapter) = await route(
        osrm([
          _step(p0, [(p0, null)]),
          _step(p1, [(p1, fork)]),
          _step(p2, [(p2, null)]),
        ]),
        fetchLanes: false,
      );
      expect(adapter.requests, hasLength(1));
      expect(result.maneuvers[1].lanes, isEmpty);
    });

    test('Map-Matching liefert die Schritte unter matchings', () {
      final base = RoutingResult(
        geometry: [
          for (final p in [p0, p1, p2]) RoutingPoint(lat: p[0], lon: p[1]),
        ],
        distanceMeters: 2200,
        durationSeconds: 80,
        maneuvers: const [
          RoutingManeuver(
            instruction: 'Los',
            lengthKm: 1.1,
            timeSeconds: 40,
            type: 1,
            beginShapeIndex: 0,
          ),
          RoutingManeuver(
            instruction: 'Links halten',
            lengthKm: 1.1,
            timeSeconds: 40,
            type: 23,
            beginShapeIndex: 1,
          ),
          RoutingManeuver(
            instruction: 'Ziel',
            lengthKm: 0,
            timeSeconds: 0,
            type: 4,
            beginShapeIndex: 2,
          ),
        ],
      );
      final result = attachLanes(
        base,
        osrm([
          _step(p0, [(p0, null)]),
          _step(p1, [(p1, fork)]),
          _step(p2, [(p2, null)]),
        ], key: 'matchings'),
      );
      expect(result.maneuvers[1].lanes, hasLength(3));

      // Und joinRoutes nimmt sie mit.
      final joined = joinRoutes([result, result]);
      expect(joined.maneuvers.where((m) => m.lanes.isNotEmpty), hasLength(2));
    });
  });
}
