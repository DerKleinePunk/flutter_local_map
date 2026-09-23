import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:local_map/local_map.dart' show LatLng, MapController;

/// Messlauf fuer die Ladezeit der Karte.
///
/// Aktiv nur mit der Umgebungsvariable `LOCAL_MAP_BENCH`, damit er im
/// Release-Build auf dem Pi ohne eigenen Build laeuft: `1` misst, `exit`
/// beendet die App danach. Der Datei-Cache von vector_map_tiles
/// (`/tmp/.vector_map`) muss vor dem Start leer sein, sonst misst man
/// die Festplatte statt des Renderers.
///
/// "Fertig" heisst: das Bild aendert sich nicht mehr. Gemessen wird an einer
/// verkleinerten Aufnahme der Karte, weil ein Kachelzaehler nur aus dem
/// Inneren der Bibliothek zu haben waere und sich mit jedem Patch daran
/// verschieben wuerde - die Aufnahme bleibt vorher wie nachher dieselbe.
class MapBench {
  MapBench._(this._exitWhenDone);

  static MapBench? fromEnvironment() {
    final value = Platform.environment['LOCAL_MAP_BENCH'];
    if (value == null || value.isEmpty || value == '0') return null;
    return MapBench._(value == 'exit');
  }

  final bool _exitWhenDone;
  final GlobalKey boundaryKey = GlobalKey();
  final MapController mapController = MapController();

  static const _sampleInterval = Duration(milliseconds: 100);

  /// So lange muss das Bild stillstehen. Deutlich laenger als das
  /// Einblenden einer Kachel in flutter_map (100 ms) und als die Aussetzer,
  /// mit denen WSLg den Prozess anhaelt - mit 1,5 s galten Ziele nach einem
  /// einzigen Frame als fertig.
  static const _stableFor = Duration(seconds: 3);
  static const _timeout = Duration(seconds: 60);

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
    unawaited(_run(sinceMain));
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

    var sum = Duration.zero;
    for (final (name, center, zoom) in _steps) {
      final before = await _snapshotHash();
      mapController.move(center, zoom);
      final result = await _measure(before: before);
      sum += result.total;
      _report(name, result);
    }
    _log('Summe der Ziele: ${sum.inMilliseconds} ms');

    if (_exitWhenDone) {
      // print geht ueber die Engine ins Log; ohne Pause verschluckt exit()
      // die letzten Zeilen.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    }
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
