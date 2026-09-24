import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:latlong2/latlong.dart';

import '../api/routing.dart';

/// [RoutingProvider], der einen Valhalla-Server per HTTP fragt.
///
/// Standard-Endpunkt: http://127.0.0.1:8002
class ValhallaRoutingService implements RoutingProvider {
  final Dio _dio;
  final Uri _baseUri;

  /// Sprache der Manöveranweisungen (Valhalla-Sprachcode). Ohne Angabe
  /// antwortet Valhalla englisch.
  final String language;

  ValhallaRoutingService({Dio? dio, Uri? baseUri, this.language = 'de-DE'})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 10),
              contentType: Headers.jsonContentType,
              responseType: ResponseType.json,
            ),
          ),
      _baseUri = baseUri ?? Uri.parse('http://127.0.0.1:8002');

  /// Adresse des Servers, für Meldungen an den Benutzer.
  Uri get baseUri => _baseUri;

  @override
  Future<RoutingResult> route({
    LatLng? start,
    required LatLng end,
    String costing = 'auto',
    String units = 'kilometers',
  }) async {
    if (start == null) {
      throw const RoutingException(
        'Kein Startpunkt: Valhalla kennt die eigene Position nicht.',
      );
    }
    final requestBody = {
      'locations': [
        {'lat': start.latitude, 'lon': start.longitude},
        {'lat': end.latitude, 'lon': end.longitude},
      ],
      'costing': costing,
      'directions_options': {'units': units, 'language': language},
    };

    return _post('/route', requestBody);
  }

  /// Legt eine aufgezeichnete Fahrt auf das Straßennetz (Map-Matching) und
  /// liefert sie als Route, mit Manövern wie [route].
  ///
  /// Anders als [route] berechnet Valhalla dabei keinen eigenen Weg, sondern
  /// folgt [trace] - die Route ist also genau die gefahrene Strecke. Das
  /// braucht, wer eine Aufzeichnung abspielt und die Anweisungen dazu passend
  /// sehen will.
  Future<RoutingResult> routeAlongTrace(
    List<LatLng> trace, {
    String costing = 'auto',
    String units = 'kilometers',
  }) async {
    if (trace.length < 2) {
      throw const RoutingException('Spur braucht mindestens zwei Punkte.');
    }
    // Stehzeiten liefern denselben Punkt viele Male. Für das Matching
    // bringen sie nichts, kosten aber Rechenzeit.
    final points = <LatLng>[];
    for (final p in trace) {
      final last = points.isEmpty ? null : points.last;
      if (last != null &&
          last.latitude == p.latitude &&
          last.longitude == p.longitude) {
        continue;
      }
      points.add(p);
    }

    // Valhalla matcht eine Spur, die ihre eigene Strecke wieder befährt,
    // nur zum Teil: eine 45-km-Hin-und-Rückfahrt kam als 22,7 km zurück,
    // ihre Hälften einzeln dagegen vollständig. Deshalb dort teilen und die
    // Stücke wieder zusammensetzen.
    final pieces = <RoutingResult>[];
    for (final piece in splitTraceAtOverlaps(points)) {
      pieces.add(
        await _post('/trace_route', {
          'shape': [
            for (final p in piece) {'lat': p.latitude, 'lon': p.longitude},
          ],
          'costing': costing,
          'shape_match': 'map_snap',
          'directions_options': {'units': units, 'language': language},
        }),
      );
    }
    return joinRoutes(pieces);
  }

  Future<RoutingResult> _post(String path, Map<String, dynamic> body) async {
    final uri = _baseUri.resolve(path);

    try {
      final response = await _dio.postUri(uri, data: body);
      final data = response.data;

      if (data is! Map<String, dynamic>) {
        throw const RoutingException(
          'Unerwartetes Antwortformat von Valhalla.',
        );
      }

      return _parseRouteResponse(data);
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      final errorBody = error.response?.data;

      if (errorBody is Map<String, dynamic>) {
        final message = errorBody['error'] ?? errorBody['message'];
        if (message is String && message.isNotEmpty) {
          throw RoutingException('Valhalla-Fehler ($statusCode): $message');
        }
      }

      throw RoutingException(
        'Valhalla nicht erreichbar (${statusCode ?? 'ohne Statuscode'}): ${error.message}',
      );
    }
  }

  @override
  Future<bool> isAvailable() async {
    final uri = _baseUri.resolve('/status');

    try {
      final response = await _dio.getUri(uri);
      return response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! < 300;
    } on DioException {
      return false;
    }
  }

  RoutingResult _parseRouteResponse(Map<String, dynamic> responseBody) {
    final trip = responseBody['trip'];
    if (trip is! Map<String, dynamic>) {
      throw const RoutingException('Antwort enthält kein trip-Objekt.');
    }

    final legsRaw = trip['legs'];
    if (legsRaw is! List || legsRaw.isEmpty) {
      throw const RoutingException('Antwort enthält keine legs.');
    }

    final geometry = <RoutingPoint>[];
    final maneuvers = <RoutingManeuver>[];
    double distanceKm = 0.0;
    int durationSeconds = 0;

    for (final legRaw in legsRaw) {
      if (legRaw is! Map<String, dynamic>) {
        continue;
      }

      final legShapeOffset = geometry.length;
      final shape = legRaw['shape'];
      if (shape is String && shape.isNotEmpty) {
        geometry.addAll(_decodePolyline(shape, precision: 6));
      }

      final summary = legRaw['summary'];
      if (summary is Map<String, dynamic>) {
        final length = summary['length'];
        final time = summary['time'];
        if (length is num) {
          distanceKm += length.toDouble();
        }
        if (time is num) {
          durationSeconds += time.toInt();
        }
      }

      final legManeuversRaw = legRaw['maneuvers'];
      if (legManeuversRaw is List) {
        for (final maneuverRaw in legManeuversRaw) {
          if (maneuverRaw is! Map<String, dynamic>) {
            continue;
          }
          final instruction = maneuverRaw['instruction'];
          final length = maneuverRaw['length'];
          final time = maneuverRaw['time'];
          final type = maneuverRaw['type'];
          final beginShapeIndex = maneuverRaw['begin_shape_index'];
          final streetNames = maneuverRaw['street_names'];

          maneuvers.add(
            RoutingManeuver(
              instruction: instruction is String ? instruction : '',
              lengthKm: length is num ? length.toDouble() : 0.0,
              timeSeconds: time is num ? time.toInt() : 0,
              type: type is int ? type : null,
              // Jede Leg zaehlt ihre Indizes ab 0, die Geometrie haengt die
              // Legs aber aneinander - daher um den bisherigen Umfang
              // verschieben.
              beginShapeIndex: beginShapeIndex is int
                  ? legShapeOffset + beginShapeIndex
                  : null,
              streetNames: streetNames is List
                  ? streetNames.whereType<String>().toList()
                  : const <String>[],
            ),
          );
        }
      }
    }

    if (geometry.isEmpty) {
      throw const RoutingException('Route enthält keine Geometrie.');
    }

    return RoutingResult(
      geometry: geometry,
      distanceMeters: distanceKm * 1000,
      durationSeconds: durationSeconds,
      maneuvers: maneuvers,
    );
  }

  List<RoutingPoint> _decodePolyline(String encoded, {int precision = 6}) {
    final coordinates = <RoutingPoint>[];
    final factor = _pow10(precision).toDouble();

    int index = 0;
    int lat = 0;
    int lon = 0;

    while (index < encoded.length) {
      final latChangeResult = _decodePolylineValue(encoded, index);
      lat += latChangeResult.value;
      index = latChangeResult.nextIndex;

      final lonChangeResult = _decodePolylineValue(encoded, index);
      lon += lonChangeResult.value;
      index = lonChangeResult.nextIndex;

      coordinates.add(RoutingPoint(lat: lat / factor, lon: lon / factor));
    }

    return coordinates;
  }

  _DecodedValue _decodePolylineValue(String encoded, int startIndex) {
    int result = 0;
    int shift = 0;
    int index = startIndex;

    while (true) {
      if (index >= encoded.length) {
        throw const RoutingException(
          'Ungültige Polyline-Antwort von Valhalla.',
        );
      }

      final int byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;

      if (byte < 0x20) {
        break;
      }
    }

    final int value = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    return _DecodedValue(value: value, nextIndex: index);
  }

  int _pow10(int exp) {
    int value = 1;
    for (int i = 0; i < exp; i++) {
      value *= 10;
    }
    return value;
  }
}

class _DecodedValue {
  final int value;
  final int nextIndex;

  const _DecodedValue({required this.value, required this.nextIndex});
}

/// Teilt eine Spur dort, wo sie ihre eigene frühere Strecke wieder
/// befährt: sobald ein Punkt näher als [radiusMeters] an einem Punkt
/// desselben Stücks liegt, der mehr als [minPathGapMeters] Fahrweg zurück
/// liegt. So wird eine Hin- und Rückfahrt am Umkehrpunkt geteilt, eine
/// Kurve oder ein Halt an der Ampel aber nicht. Benachbarte Stücke teilen
/// sich einen Punkt.
List<List<LatLng>> splitTraceAtOverlaps(
  List<LatLng> trace, {
  double radiusMeters = 25,
  double minPathGapMeters = 300,
}) {
  if (trace.length < 3) return [trace];

  final path = List<double>.filled(trace.length, 0);
  for (var i = 1; i < trace.length; i++) {
    path[i] = path[i - 1] + _flatMeters(trace[i - 1], trace[i]);
  }

  final pieces = <List<LatLng>>[];
  var start = 0;
  for (var i = start + 1; i < trace.length; i++) {
    for (var j = start; j < i; j++) {
      if (path[i] - path[j] <= minPathGapMeters) break;
      if (_flatMeters(trace[i], trace[j]) < radiusMeters) {
        pieces.add(trace.sublist(start, i));
        start = i - 1;
        break;
      }
    }
  }
  pieces.add(trace.sublist(start));
  return pieces;
}

/// Abstand in einer Plattkarten-Näherung - für Punkte, die höchstens
/// einige Kilometer auseinander liegen, genau genug und viel billiger als
/// die Kugelformel, die hier millionenfach liefe.
double _flatMeters(LatLng a, LatLng b) {
  const metersPerDegree = 111319.49;
  final cosLat = math.cos(a.latitude * math.pi / 180);
  final dx = (b.longitude - a.longitude) * cosLat * metersPerDegree;
  final dy = (b.latitude - a.latitude) * metersPerDegree;
  return math.sqrt(dx * dx + dy * dy);
}

/// Setzt nacheinander gefahrene Routenstücke zu einer Route zusammen.
///
/// Die Geometrie wird aneinandergehängt, die Manöver-Indizes verschoben.
/// Das "Ziel erreicht" am Ende eines Stücks fällt weg, außer beim letzten.
RoutingResult joinRoutes(List<RoutingResult> pieces) {
  if (pieces.length == 1) return pieces.single;
  final geometry = <RoutingPoint>[];
  final maneuvers = <RoutingManeuver>[];
  var distanceMeters = 0.0;
  var durationSeconds = 0;
  for (var i = 0; i < pieces.length; i++) {
    final piece = pieces[i];
    final offset = geometry.length;
    geometry.addAll(piece.geometry);
    distanceMeters += piece.distanceMeters;
    durationSeconds += piece.durationSeconds;
    final isLast = i == pieces.length - 1;
    for (final m in piece.maneuvers) {
      if (!isLast && _isArrival(m.type)) continue;
      final begin = m.beginShapeIndex;
      maneuvers.add(
        RoutingManeuver(
          instruction: m.instruction,
          lengthKm: m.lengthKm,
          timeSeconds: m.timeSeconds,
          type: m.type,
          beginShapeIndex: begin == null ? null : begin + offset,
          streetNames: m.streetNames,
        ),
      );
    }
  }
  return RoutingResult(
    geometry: geometry,
    distanceMeters: distanceMeters,
    durationSeconds: durationSeconds,
    maneuvers: maneuvers,
  );
}

/// Valhalla: 4 Ziel, 5 Ziel rechts, 6 Ziel links.
bool _isArrival(int? type) => type == 4 || type == 5 || type == 6;
