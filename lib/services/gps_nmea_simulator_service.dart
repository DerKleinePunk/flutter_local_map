import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

class SimulatedGpsFix {
  final LatLng position;
  final DateTime? timestampUtc;
  final String sourceSentence;

  const SimulatedGpsFix({
    required this.position,
    required this.timestampUtc,
    required this.sourceSentence,
  });
}

class GpsNmeaSimulatorService {
  final StreamController<SimulatedGpsFix> _controller =
      StreamController<SimulatedGpsFix>.broadcast();

  final List<SimulatedGpsFix> _fixes = <SimulatedGpsFix>[];

  Timer? _timer;
  int _currentIndex = 0;

  Stream<SimulatedGpsFix> get fixes => _controller.stream;

  bool get isRunning => _timer != null;
  bool get hasData => _fixes.isNotEmpty;
  int get fixCount => _fixes.length;

  Future<int> loadFromPath(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('GPS-Logdatei nicht gefunden: $path');
    }

    final lines = await file.readAsLines();
    return loadFromLines(lines);
  }

  int loadFromLines(List<String> lines) {
    _fixes
      ..clear()
      ..addAll(_parseFixes(lines));
    _currentIndex = 0;
    return _fixes.length;
  }

  Future<int> loadDefaultTourFile() async {
    final cwd = Directory.current.path;
    final candidates = <String>[
      '$cwd/scripts/gpstest/GPS-Adnan-Tour.txt',
      '$cwd/scripts/GpsTest/GPS-Adnan-Tour.txt',
    ];

    for (final path in candidates) {
      final file = File(path);
      if (await file.exists()) {
        return loadFromPath(path);
      }
    }

    throw Exception(
      'Keine GPS-Tourdatei gefunden. Erwartet unter scripts/gpstest oder scripts/GpsTest.',
    );
  }

  void start({
    Duration interval = const Duration(seconds: 1),
    bool loop = true,
  }) {
    if (_fixes.isEmpty) {
      throw Exception('Keine GPS-Fixes geladen.');
    }

    stop();

    _timer = Timer.periodic(interval, (_) {
      if (_currentIndex >= _fixes.length) {
        if (!loop) {
          stop();
          return;
        }
        _currentIndex = 0;
      }

      _controller.add(_fixes[_currentIndex]);
      _currentIndex++;
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void reset() {
    _currentIndex = 0;
  }

  void dispose() {
    stop();
    _controller.close();
  }

  List<SimulatedGpsFix> _parseFixes(List<String> lines) {
    final parsed = <SimulatedGpsFix>[];

    for (final raw in lines) {
      final line = raw.trim();
      if (!line.startsWith(r'$GP')) {
        continue;
      }

      final payload = line.split('*').first;
      final fields = payload.split(',');
      if (fields.isEmpty) {
        continue;
      }

      final type = fields.first;
      if (type == r'$GPRMC') {
        final fix = _parseRmc(fields, payload);
        if (fix != null) {
          parsed.add(fix);
        }
      } else if (type == r'$GPGGA') {
        final fix = _parseGga(fields, payload);
        if (fix != null) {
          parsed.add(fix);
        }
      }
    }

    return parsed;
  }

  SimulatedGpsFix? _parseRmc(List<String> fields, String source) {
    if (fields.length < 10) {
      return null;
    }

    final status = fields[2];
    if (status != 'A') {
      return null;
    }

    final lat = _parseNmeaCoordinate(fields[3], fields[4], isLatitude: true);
    final lon = _parseNmeaCoordinate(fields[5], fields[6], isLatitude: false);

    if (lat == null || lon == null) {
      return null;
    }

    final timestamp = _parseUtcDateTime(fields[1], fields[9]);
    return SimulatedGpsFix(
      position: LatLng(lat, lon),
      timestampUtc: timestamp,
      sourceSentence: source,
    );
  }

  SimulatedGpsFix? _parseGga(List<String> fields, String source) {
    if (fields.length < 7) {
      return null;
    }

    final fixQuality = int.tryParse(fields[6]) ?? 0;
    if (fixQuality <= 0) {
      return null;
    }

    final lat = _parseNmeaCoordinate(fields[2], fields[3], isLatitude: true);
    final lon = _parseNmeaCoordinate(fields[4], fields[5], isLatitude: false);

    if (lat == null || lon == null) {
      return null;
    }

    final timestamp = _parseUtcDateTime(fields[1], null);
    if (kDebugMode) {
      final timestamp = DateTime.now().toIso8601String();
      print('[$timestamp] Parsed GGA fix: lat=$lat, lon=$lon, time=$timestamp');
    }

    return SimulatedGpsFix(
      position: LatLng(lat, lon),
      timestampUtc: timestamp,
      sourceSentence: source,
    );
  }

  double? _parseNmeaCoordinate(
    String value,
    String hemisphere, {
    required bool isLatitude,
  }) {
    if (value.isEmpty || hemisphere.isEmpty) {
      return null;
    }

    final raw = double.tryParse(value);
    if (raw == null) {
      return null;
    }

    final degreeDigits = isLatitude ? 2 : 3;
    final divisor = _pow10(degreeDigits);
    final degrees = (raw / divisor).floorToDouble();
    final minutes = raw - (degrees * divisor);

    var decimal = degrees + (minutes / 60.0);
    if (hemisphere == 'S' || hemisphere == 'W') {
      decimal *= -1;
    }

    return decimal;
  }

  DateTime? _parseUtcDateTime(String hhmmss, String? ddmmyy) {
    if (hhmmss.length < 6) {
      return null;
    }

    final hour = int.tryParse(hhmmss.substring(0, 2));
    final minute = int.tryParse(hhmmss.substring(2, 4));
    final second = int.tryParse(hhmmss.substring(4, 6));

    if (hour == null || minute == null || second == null) {
      return null;
    }

    if (ddmmyy == null || ddmmyy.length < 6) {
      final now = DateTime.now().toUtc();
      return DateTime.utc(now.year, now.month, now.day, hour, minute, second);
    }

    final day = int.tryParse(ddmmyy.substring(0, 2));
    final month = int.tryParse(ddmmyy.substring(2, 4));
    final yearShort = int.tryParse(ddmmyy.substring(4, 6));

    if (day == null || month == null || yearShort == null) {
      return null;
    }

    final year = 2000 + yearShort;
    return DateTime.utc(year, month, day, hour, minute, second);
  }

  double _pow10(int exponent) {
    var result = 1.0;
    for (var i = 0; i < exponent; i++) {
      result *= 10.0;
    }
    return result;
  }
}
