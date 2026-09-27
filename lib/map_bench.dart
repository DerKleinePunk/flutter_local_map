import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:local_map/local_map.dart'
    show GpsNmeaSimulatorService, LatLng, MapController;

/// Messlauf fuer die Karte.
///
/// Aktiv nur mit der Umgebungsvariable `LOCAL_MAP_BENCH`, damit er im
/// Release-Build auf dem Pi ohne eigenen Build laeuft: `1` misst die
/// Ladeziele, `exit` beendet die App danach. `drive`/`drive-exit` faehrt
/// stattdessen die GPS-Tour ab und misst die Frames dabei - der Betrieb,
/// nicht das Laden (LOCAL_MAP_BENCH_SPEED-fach, Vorgabe 20; Dauer
/// LOCAL_MAP_BENCH_DRIVE_S, Vorgabe 120; Zoom LOCAL_MAP_BENCH_ZOOM,
/// Vorgabe 14; Tourdatei LOCAL_MAP_BENCH_TOUR statt der Demo-Tour).
/// Der Datei-Cache von vector_map_tiles (`/tmp/.vector_map`) muss beim
/// Ladelauf vorher leer sein, sonst misst man die Festplatte statt des
/// Renderers.
///
/// "Fertig" heisst: das Bild aendert sich nicht mehr. Gemessen wird an einer
/// verkleinerten Aufnahme der Karte, weil ein Kachelzaehler nur aus dem
/// Inneren der Bibliothek zu haben waere und sich mit jedem Patch daran
/// verschieben wuerde - die Aufnahme bleibt vorher wie nachher dieselbe.
class MapBench {
  MapBench._(this._exitWhenDone, this._drive);

  static MapBench? fromEnvironment() {
    final value = Platform.environment['LOCAL_MAP_BENCH'];
    if (value == null || value.isEmpty || value == '0') return null;
    return MapBench._(value.endsWith('exit'), value.startsWith('drive'));
  }

  final bool _exitWhenDone;
  final bool _drive;

  /// `drive-gps`: die GPS-Simulation faehrt (MapScreen startet sie samt
  /// Folgemodus), der Bench misst nur die Frames. Nur so laeuft auch das
  /// Vorab-Laden mit, das echte Fixe braucht.
  bool get driveGps =>
      (Platform.environment['LOCAL_MAP_BENCH'] ?? '').startsWith('drive-gps');
  final GlobalKey boundaryKey = GlobalKey();
  final MapController mapController = MapController();

  static const _sampleInterval = Duration(milliseconds: 100);

  /// So lange muss das Bild stillstehen. Deutlich laenger als das
  /// Einblenden einer Kachel in flutter_map (100 ms) und als die Aussetzer,
  /// mit denen WSLg den Prozess anhaelt - mit 1,5 s galten Ziele nach einem
  /// einzigen Frame als fertig. Mit `LOCAL_MAP_BENCH_STABLE_MS` verstellbar,
  /// um zu pruefen, ob ein Ziel nur langsam oder wirklich fertig ist.
  static final _stableFor = Duration(
    milliseconds:
        int.tryParse(Platform.environment['LOCAL_MAP_BENCH_STABLE_MS'] ?? '') ??
        3000,
  );
  static const _timeout = Duration(seconds: 60);

  /// Verzeichnis fuer eine Aufnahme je Ziel als PNG, gesetzt ueber
  /// `LOCAL_MAP_BENCH_SHOTS`. Unter WSLg und auf dem Pi gibt es kein
  /// Bildschirmfoto von aussen; so laesst sich trotzdem nachsehen, was die
  /// Karte gezeichnet hat, etwa ob Beschriftungen da sind.
  static final _shotsDir = Platform.environment['LOCAL_MAP_BENCH_SHOTS'];

  /// Feste Ziele, damit Laeufe vergleichbar sind. Jedes liegt ausserhalb
  /// des vorigen, nur das letzte kehrt zurueck und misst den Cache.
  static final _steps = <(String, LatLng, double)>[
    ('Frankfurt z14', const LatLng(50.1109, 8.6821), 14),
    ('Alsfeld z12', const LatLng(50.7519, 9.2692), 12),
    ('Kassel z11', const LatLng(51.3127, 9.4797), 11),
    ('Mittelhessen z9', const LatLng(50.60, 9.00), 9),
    ('Hessen z8', const LatLng(50.60, 9.00), 8),
    ('zurueck Frankfurt z14', const LatLng(50.1109, 8.6821), 14),
  ];

  final _frames = <FrameTiming>[];
  bool _started = false;

  /// Startet den Lauf, sobald die Karte steht. Mehrfachaufrufe sind harmlos.
  void start(Stopwatch sinceMain) {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(_frames.addAll);
    unawaited(_drive ? _runDrive() : _run(sinceMain));
  }

  Future<void> _run(Stopwatch sinceMain) async {
    _log(
      'Start, ${_steps.length} Ziele, Cache leer: '
      '${!Directory('/tmp/.vector_map').existsSync()}',
    );

    await _waitForCamera();
    final measureFrom = sinceMain.elapsed;
    final first = await _measure(before: null);
    _report('Start (ab main)', first, offset: measureFrom);
    await _saveShot(0, 'start');

    var sum = Duration.zero;
    var index = 0;
    for (final (name, center, zoom) in _steps) {
      final before = await _snapshotHash();
      mapController.move(center, zoom);
      final result = await _measure(before: before);
      sum += result.total;
      _report(name, result);
      await _saveShot(++index, name);
    }
    _log('Summe der Ziele: ${sum.inMilliseconds} ms');

    if (_exitWhenDone) {
      // print geht ueber die Engine ins Log; ohne Pause verschluckt exit()
      // die letzten Zeilen.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    }
  }

  /// Faehrt die GPS-Tour ab wie der Navigationsmodus: Position und Drehung
  /// folgen den Fixen, beschleunigt abgespielt. Gemessen werden nur die
  /// Frame-Zeiten - kein Bildvergleich, der wuerde selbst Last erzeugen.
  Future<void> _runDrive() async {
    if (driveGps) {
      return _measureOnly();
    }
    final sim = GpsNmeaSimulatorService();
    final tour = Platform.environment['LOCAL_MAP_BENCH_TOUR'];
    final count = tour == null || tour.isEmpty
        ? await sim.loadDefaultTourFile()
        : await sim.loadFromPath(tour);
    double envDouble(String name, double fallback) =>
        double.tryParse(Platform.environment[name] ?? '') ?? fallback;
    final zoom = envDouble('LOCAL_MAP_BENCH_ZOOM', 14);
    final speed = envDouble('LOCAL_MAP_BENCH_SPEED', 20);
    final duration = Duration(
      seconds: envDouble('LOCAL_MAP_BENCH_DRIVE_S', 120).round(),
    );

    // Zeitachse der Aufzeichnung, Luecken gedeckelt wie beim Abspielen.
    final fixes = sim.loadedFixes;
    final at = <double>[0];
    for (var i = 1; i < fixes.length; i++) {
      final now = fixes[i].timestampUtc;
      final prev = fixes[i - 1].timestampUtc;
      // Ohne Zeitstempel gilt der Sekundentakt eines GPS-Empfaengers.
      var gap = now == null || prev == null
          ? const Duration(seconds: 1)
          : now.difference(prev);
      if (gap > GpsNmeaSimulatorService.maxReplayGap) {
        gap = GpsNmeaSimulatorService.maxReplayGap;
      }
      if (gap.isNegative) gap = Duration.zero;
      at.add(at.last + gap.inMilliseconds / 1000);
    }

    await _waitForCamera();
    await _measure(before: null); // erst wenn die Karte steht, zaehlt Fahrt
    _log(
      'Fahrt: $count Fixe, ${speed}x, Zoom $zoom, '
      'hoechstens ${duration.inSeconds} s',
    );
    _frames.clear();
    final clock = Stopwatch()..start();
    var index = 0;
    while (clock.elapsed < duration) {
      await Future<void>.delayed(_sampleInterval);
      final virtualSeconds = clock.elapsedMilliseconds / 1000 * speed;
      while (index + 1 < fixes.length && at[index + 1] <= virtualSeconds) {
        index++;
      }
      final fix = fixes[index];
      final heading = (fix.speedMps ?? 0) > 1 ? fix.headingDegrees : null;
      if (heading == null) {
        mapController.move(fix.position, zoom);
      } else {
        // Fahrtrichtung oben, wie im Navigationsmodus.
        mapController.moveAndRotate(fix.position, zoom, -heading);
      }
      if (index + 1 >= fixes.length) break;
    }
    _reportDrive(
      _Result(clock.elapsed, List.of(_frames), false),
      coveredFixes: index + 1,
      totalFixes: fixes.length,
    );
    if (_exitWhenDone) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    }
  }

  /// Misst die Frames, waehrend die GPS-Simulation die Kamera fuehrt.
  Future<void> _measureOnly() async {
    final duration = Duration(
      seconds:
          (double.tryParse(
                    Platform.environment['LOCAL_MAP_BENCH_DRIVE_S'] ?? '',
                  ) ??
                  120)
              .round(),
    );
    await _waitForCamera();
    await _measure(before: null);
    _log('Fahrt (GPS-Sim): ${duration.inSeconds} s Messung beginnt');
    _frames.clear();
    await Future<void>.delayed(duration);
    _reportDrive(
      _Result(duration, List.of(_frames), false),
      coveredFixes: 0,
      totalFixes: 0,
    );
    if (_exitWhenDone) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    }
  }

  void _reportDrive(
    _Result r, {
    required int coveredFixes,
    required int totalFixes,
  }) {
    final spans = r.frames.map((f) => f.totalSpan.inMicroseconds).toList()
      ..sort();
    final builds = r.frames.map((f) => f.buildDuration.inMicroseconds).toList()
      ..sort();
    final rasters =
        r.frames.map((f) => f.rasterDuration.inMicroseconds).toList()..sort();
    int over(int ms) => spans.where((us) => us > ms * 1000).length;
    String ms(int us) => (us / 1000).toStringAsFixed(1);
    _log(
      'Fahrt fertig: ${r.total.inMilliseconds} ms, $coveredFixes/$totalFixes '
      'Fixe | ${r.frames.length} Frames, ueber 33/100/300 ms: '
      '${over(33)}/${over(100)}/${over(300)}, schlechtester '
      '${ms(spans.isEmpty ? 0 : spans.last)} ms | Build p90 '
      '${ms(_p90(builds))} ms | Raster p90 ${ms(_p90(rasters))} max '
      '${ms(rasters.isEmpty ? 0 : rasters.last)} ms',
    );
  }

  Future<void> _waitForCamera() async {
    while (true) {
      try {
        mapController.camera;
        return;
      } catch (_) {
        await Future<void>.delayed(_sampleInterval);
      }
    }
  }

  /// Wartet, bis das Bild [_stableFor] lang stillsteht. Solange es noch
  /// dem Bild vor dem Sprung ([before]) gleicht, zaehlt Stillstand nicht:
  /// dann hat die Karte den Sprung noch gar nicht gezeichnet.
  Future<_Result> _measure({required int? before}) async {
    _frames.clear();
    final clock = Stopwatch()..start();
    int? lastHash = before;
    var lastChange = Duration.zero;
    var moved = before == null;
    var timedOut = false;

    while (true) {
      await Future<void>.delayed(_sampleInterval);
      final hash = await _snapshotHash();
      if (hash != null && hash != lastHash) {
        lastHash = hash;
        lastChange = clock.elapsed;
        moved = true;
      }
      if (moved && clock.elapsed - lastChange >= _stableFor) break;
      if (clock.elapsed >= _timeout) {
        timedOut = true;
        break;
      }
    }
    return _Result(lastChange, List.of(_frames), timedOut);
  }

  Future<int?> _snapshotHash() async {
    final boundary = boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;
    final image = await boundary.toImage(pixelRatio: 0.25);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      // FNV-1a ueber 32-Bit-Worte: schnell genug fuer zehn Aufnahmen pro
      // Sekunde auf dem Pi, und jede geaenderte Kachel aendert den Wert.
      final words = data.buffer.asUint32List();
      var h = 0x811c9dc5;
      for (final w in words) {
        h = ((h ^ w) * 0x01000193) & 0xffffffff;
      }
      return h;
    } finally {
      image.dispose();
    }
  }

  Future<void> _saveShot(int index, String name) async {
    final dir = _shotsDir;
    if (dir == null || dir.isEmpty) return;
    final boundary = boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return;
    final image = await boundary.toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final slug = name.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
      final file = File('$dir/${index.toString().padLeft(2, '0')}_$slug.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List());
      _log('Aufnahme: ${file.path}');
    } finally {
      image.dispose();
    }
  }

  void _report(String name, _Result r, {Duration offset = Duration.zero}) {
    final builds = r.frames.map((f) => f.buildDuration.inMicroseconds).toList()
      ..sort();
    final rasters =
        r.frames.map((f) => f.rasterDuration.inMicroseconds).toList()..sort();
    final slow = r.frames
        .where((f) => f.totalSpan > const Duration(milliseconds: 33))
        .length;
    String ms(int us) => (us / 1000).toStringAsFixed(1);
    _log(
      '$name: fertig nach ${(offset + r.total).inMilliseconds} ms'
      '${r.timedOut ? ' (ZEITLIMIT)' : ''} | ${r.frames.length} Frames, '
      '$slow ueber 33 ms | Build p90 ${ms(_p90(builds))} max '
      '${ms(builds.isEmpty ? 0 : builds.last)} ms | Raster p90 '
      '${ms(_p90(rasters))} max ${ms(rasters.isEmpty ? 0 : rasters.last)} ms',
    );
  }

  static int _p90(List<int> sorted) => sorted.isEmpty
      ? 0
      : sorted[(sorted.length * 0.9).floor().clamp(0, sorted.length - 1)];

  static void _log(String message) {
    // ignore: avoid_print
    print('[bench] $message');
  }
}

class _Result {
  _Result(this.total, this.frames, this.timedOut);

  final Duration total;
  final List<FrameTiming> frames;
  final bool timedOut;
}

/// Haengt die Karte in eine [RepaintBoundary], die der Messlauf abgreift.
Widget wrapForBench(MapBench? bench, Widget map) =>
    bench == null ? map : RepaintBoundary(key: bench.boundaryKey, child: map);
