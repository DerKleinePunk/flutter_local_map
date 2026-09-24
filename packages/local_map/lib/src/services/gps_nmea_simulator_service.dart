import 'dart:async';
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

import '../api/position.dart';
import '../config/map_config.dart';

/// Positionsmeldung aus einer NMEA-Aufzeichnung.
class SimulatedGpsFix extends PositionFix {
  final String sourceSentence;

  const SimulatedGpsFix({
    required super.position,
    required super.timestampUtc,
    required this.sourceSentence,
    super.headingDegrees,
    super.speedMps,
  });
}

/// Spielt eine NMEA-Aufzeichnung als [PositionSource] ab.
class GpsNmeaSimulatorService implements PositionSource {
  /// Obergrenze fuer die Pause zwischen zwei Meldungen beim Abspielen im
  /// Originaltakt. Luecken in der Aufzeichnung (Tunnel, Empfaenger aus)
  /// sollen die Wiedergabe nicht minutenlang anhalten.
  static const Duration maxReplayGap = Duration(seconds: 5);

  static const double _knotsToMps = 0.514444;

  final StreamController<SimulatedGpsFix> _controller =
      StreamController<SimulatedGpsFix>.broadcast();

  final List<SimulatedGpsFix> _fixes = <SimulatedGpsFix>[];

  Timer? _timer;
  bool _running = false;
  int _currentIndex = 0;

  Stream<SimulatedGpsFix> get fixes => _controller.stream;

  @override
  Stream<PositionFix> get positions => _controller.stream;

  bool get isRunning => _running;
  bool get hasData => _fixes.isNotEmpty;

  /// Alle geladenen Meldungen, etwa um die Fahrt als Route anzuzeigen.
  List<SimulatedGpsFix> get loadedFixes => List.unmodifiable(_fixes);
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

  /// Lädt die erste vorhandene Tourdatei aus [candidatePaths].
  ///
  /// Relative Pfade werden gegen das aktuelle Arbeitsverzeichnis aufgelöst.
  /// Wird nichts übergeben, greift [MapConfig.defaults].
  Future<int> loadDefaultTourFile({List<String>? candidatePaths}) async {
    final candidates = candidatePaths ?? MapConfig.defaults.gpsTourFilePaths;
    final resolved = candidates
        .map(
          (path) =>
              p.isAbsolute(path) ? path : p.join(Directory.current.path, path),
        )
        .toList();

    for (final path in resolved) {
      final file = File(path);
      if (await file.exists()) {
        return loadFromPath(path);
      }
    }

    throw Exception(
      'Keine GPS-Tourdatei gefunden. Gesucht wurde in: '
      '${resolved.join(", ")}',
    );
  }

  /// Startet die Wiedergabe.
  ///
  /// Ohne [interval] laeuft sie im Takt der Aufzeichnung, geteilt durch
  /// [speedFactor]; Pausen sind auf [maxReplayGap] begrenzt. Mit [interval]
  /// kommt jede Meldung in festem Abstand.
  void start({Duration? interval, bool loop = true, double speedFactor = 1}) {
    if (_fixes.isEmpty) {
      throw Exception('Keine GPS-Fixes geladen.');
    }
    if (speedFactor <= 0) {
      throw ArgumentError.value(speedFactor, 'speedFactor', 'muss > 0 sein');
    }

    stop();
    _running = true;

    void emitNext() {
      if (!_running) {
        return;
      }
      if (_currentIndex >= _fixes.length) {
        if (!loop) {
          stop();
          return;
        }
        _currentIndex = 0;
      }

      final fix = _fixes[_currentIndex];
      _controller.add(fix);
      _currentIndex++;

      final next = _currentIndex < _fixes.length ? _fixes[_currentIndex] : null;
      _timer = Timer(
        interval ?? _replayDelay(fix, next, speedFactor),
        emitNext,
      );
    }

    // Die erste Meldung sofort, damit die Karte nicht erst eine Pause lang
    // auf den Positionspfeil wartet.
    _timer = Timer(Duration.zero, emitNext);
  }

  Duration _replayDelay(
    SimulatedGpsFix current,
    SimulatedGpsFix? next,
    double speedFactor,
  ) {
    final from = current.timestampUtc;
    final to = next?.timestampUtc;
    var gap = const Duration(seconds: 1);
    if (from != null && to != null) {
      gap = to.difference(from);
      // Mitternacht oder eine Aufzeichnung ohne Datum: die Differenz wird
      // negativ. Dann im Sekundentakt weiter.
      if (gap.isNegative) {
        gap = const Duration(seconds: 1);
      }
    }
    if (gap > maxReplayGap) {
      gap = maxReplayGap;
    }
    return gap * (1 / speedFactor);
  }

  void stop() {
    _running = false;
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
    final rmc = <SimulatedGpsFix>[];
    final gga = <SimulatedGpsFix>[];

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
          rmc.add(fix);
        }
      } else if (type == r'$GPGGA') {
        final fix = _parseGga(fields, payload);
        if (fix != null) {
          gga.add(fix);
        }
      }
    }

    // Ein Empfaenger schickt je Sekunde meist beide Saetze fuer dieselbe
    // Position. Gemischt kaeme jede Position doppelt, und die GGA-Haelfte
    // haette keinen Kurs - die Karte wuerde im Sekundentakt hin- und
    // herdrehen. RMC hat Kurs und Geschwindigkeit und gewinnt daher.
    return rmc.isNotEmpty ? rmc : gga;
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
    final speedKnots = double.tryParse(fields[7]);
    final course = double.tryParse(fields[8]);
    return SimulatedGpsFix(
      position: LatLng(lat, lon),
      timestampUtc: timestamp,
      sourceSentence: source,
      speedMps: speedKnots == null ? null : speedKnots * _knotsToMps,
      headingDegrees: course == null ? null : course % 360,
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

    // NMEA kodiert Koordinaten als ddmm.mmmm (Breite) bzw. dddmm.mmmm
    // (Laenge). Der Minutenanteil ist in beiden Faellen zweistellig, der
    // Gradanteil alles davor - der Teiler ist deshalb immer 100.
    //
    // Achtung: Ein Teiler von 1000 fuer die Laenge ist falsch. `00921.8766`
    // parst zu 921.8766; mit Teiler 1000 ergaebe das 0 Grad und 921,88
    // Minuten, also 15,36 statt 9,36 Grad.
    const divisor = 100.0;
    final degrees = (raw / divisor).floorToDouble();
    final minutes = raw - (degrees * divisor);

    if (minutes < 0 || minutes >= 60) {
      return null;
    }

    var decimal = degrees + (minutes / 60.0);

    // Plausibilitaet: Breite bis 90, Laenge bis 180 Grad.
    final limit = isLatitude ? 90.0 : 180.0;
    if (decimal > limit) {
      return null;
    }

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
}
