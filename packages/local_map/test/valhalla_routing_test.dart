import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';

/// Antwortet auf jede Anfrage mit einer festen Valhalla-Antwort.
class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter(this.body);

  final Map<String, dynamic> body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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
  test('Manoever-Indizes zeigen ueber alle Legs in die Gesamtgeometrie', () async {
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
  });
}
