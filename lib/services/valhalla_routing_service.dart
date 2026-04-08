import 'package:dio/dio.dart';
import 'package:latlong2/latlong.dart';

/// Repräsentiert ein Koordinatenpaar im WGS84-Format.
class RoutingPoint {
  final double lat;
  final double lon;

  const RoutingPoint({required this.lat, required this.lon});

  factory RoutingPoint.fromLatLng(LatLng value) =>
      RoutingPoint(lat: value.latitude, lon: value.longitude);

  LatLng toLatLng() => LatLng(lat, lon);
}

/// Einzelnes Turn-by-Turn-Manöver aus einer Valhalla-Antwort.
class RoutingManeuver {
  final String instruction;
  final double lengthKm;
  final int timeSeconds;
  final int? type;

  const RoutingManeuver({
    required this.instruction,
    required this.lengthKm,
    required this.timeSeconds,
    required this.type,
  });
}

/// Ergebnis einer Routingabfrage.
class RoutingResult {
  final List<RoutingPoint> geometry;
  final double distanceMeters;
  final int durationSeconds;
  final List<RoutingManeuver> maneuvers;

  const RoutingResult({
    required this.geometry,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.maneuvers,
  });
}

/// Fehlerklasse für nachvollziehbare Routing-Fehlermeldungen.
class RoutingException implements Exception {
  final String message;

  const RoutingException(this.message);

  @override
  String toString() => 'RoutingException: $message';
}

/// HTTP-Client für lokales/offline Valhalla Routing.
///
/// Standard-Endpunkt: http://127.0.0.1:8002
class ValhallaRoutingService {
  final Dio _dio;
  final Uri _baseUri;

  ValhallaRoutingService({Dio? dio, Uri? baseUri})
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

  Future<RoutingResult> route({
    required LatLng start,
    required LatLng end,
    String costing = 'auto',
    String units = 'kilometers',
  }) async {
    final requestBody = {
      'locations': [
        {'lat': start.latitude, 'lon': start.longitude},
        {'lat': end.latitude, 'lon': end.longitude},
      ],
      'costing': costing,
      'directions_options': {'units': units},
    };

    final uri = _baseUri.resolve('/route');

    try {
      final response = await _dio.postUri(uri, data: requestBody);
      final data = response.data;

      if (data is! Map<String, dynamic>) {
        throw const RoutingException(
          'Unerwartetes Antwortformat von Valhalla.',
        );
      }

      return _parseRouteResponse(data);
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;
      final body = error.response?.data;

      if (body is Map<String, dynamic>) {
        final message = body['error'] ?? body['message'];
        if (message is String && message.isNotEmpty) {
          throw RoutingException('Valhalla-Fehler ($statusCode): $message');
        }
      }

      throw RoutingException(
        'Valhalla nicht erreichbar (${statusCode ?? 'ohne Statuscode'}): ${error.message}',
      );
    }
  }

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

          maneuvers.add(
            RoutingManeuver(
              instruction: instruction is String ? instruction : '',
              lengthKm: length is num ? length.toDouble() : 0.0,
              timeSeconds: time is num ? time.toInt() : 0,
              type: type is int ? type : null,
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
