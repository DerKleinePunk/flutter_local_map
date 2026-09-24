import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';

/// Der Simulator als [PositionSource]: Kurs und Geschwindigkeit fuer den
/// Navigationsmodus, keine Doppelmeldungen, Wiedergabe im Originaltakt.
void main() {
  // Aus scripts/GpsTest/GPS-Adnan-Tour.txt: je Sekunde ein GGA und ein RMC
  // fuer dieselbe Position.
  const tour = [
    r'$GPGGA,151722.000,5024.6139,N,00921.8948,E,1,08,1.0,372.6,M,48.0,M,,0000*7C',
    r'$GPRMC,151722.000,A,5024.6139,N,00921.8948,E,10.00,87.50,210425,,,A*7C',
    r'$GPGGA,151723.000,5024.6140,N,00921.9000,E,1,08,1.0,372.6,M,48.0,M,,0000*7C',
    r'$GPRMC,151723.000,A,5024.6140,N,00921.9000,E,10.50,88.00,210425,,,A*7C',
    r'$GPGGA,151724.000,5024.6141,N,00921.9052,E,1,08,1.0,372.6,M,48.0,M,,0000*7C',
    r'$GPRMC,151724.000,A,5024.6141,N,00921.9052,E,11.00,370.00,210425,,,A*7C',
  ];

  Future<List<PositionFix>> collect(
    GpsNmeaSimulatorService sim,
    void Function() start,
    Duration wait,
  ) async {
    final collected = <PositionFix>[];
    final sub = sim.positions.listen(collected.add);
    start();
    await Future<void>.delayed(wait);
    sim.stop();
    await sub.cancel();
    return collected;
  }

  test('RMC liefert Kurs und Geschwindigkeit', () {
    final sim = GpsNmeaSimulatorService();
    sim.loadFromLines(tour);
    addTearDown(sim.dispose);

    expect(sim.fixCount, 3, reason: 'GGA-Doppel muessen wegfallen');
  });

  test('Kurs in Grad, Geschwindigkeit in m/s, Kurs auf 0..360', () async {
    final sim = GpsNmeaSimulatorService()..loadFromLines(tour);
    addTearDown(sim.dispose);

    final fixes = await collect(
      sim,
      () => sim.start(interval: const Duration(milliseconds: 1), loop: false),
      const Duration(milliseconds: 200),
    );

    expect(fixes, hasLength(3));
    expect(fixes[0].headingDegrees, closeTo(87.5, 1e-9));
    // 10 Knoten
    expect(fixes[0].speedMps, closeTo(5.14444, 1e-4));
    // 370 Grad ist 10 Grad
    expect(fixes[2].headingDegrees, closeTo(10, 1e-9));
  });

  test('nur GGA: Positionen ohne Kurs, aber vorhanden', () {
    final sim = GpsNmeaSimulatorService()
      ..loadFromLines(tour.where((l) => l.startsWith(r'$GPGGA')).toList());
    addTearDown(sim.dispose);

    expect(sim.fixCount, 3);
  });

  test('Wiedergabe im Takt der Aufzeichnung, geteilt durch speedFactor', () async {
    final sim = GpsNmeaSimulatorService()..loadFromLines(tour);
    addTearDown(sim.dispose);

    final stamps = <Duration>[];
    final watch = Stopwatch()..start();
    final sub = sim.positions.listen((_) => stamps.add(watch.elapsed));
    // Eine Sekunde Abstand in der Aufzeichnung, zehnfach beschleunigt:
    // 100 ms zwischen den Meldungen.
    sim.start(loop: false, speedFactor: 10);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    sim.stop();
    await sub.cancel();

    expect(stamps, hasLength(3));
    expect(stamps[0].inMilliseconds, lessThan(50), reason: 'erste sofort');
    final gap = (stamps[2] - stamps[0]).inMilliseconds;
    expect(gap, inInclusiveRange(180, 320));
  });

  test('Luecken in der Aufzeichnung werden gedeckelt', () async {
    final sim = GpsNmeaSimulatorService()
      ..loadFromLines([
        r'$GPRMC,151722.000,A,5024.6139,N,00921.8948,E,0.0,0.0,210425,,,A*7C',
        // zehn Minuten spaeter
        r'$GPRMC,152722.000,A,5024.6139,N,00921.8948,E,0.0,0.0,210425,,,A*7C',
      ]);
    addTearDown(sim.dispose);

    final fixes = await collect(
      sim,
      // maxReplayGap (5 s) durch 50 = 100 ms statt 12 s
      () => sim.start(loop: false, speedFactor: 50),
      const Duration(milliseconds: 400),
    );

    expect(fixes, hasLength(2));
  });

  test('Simulator ist eine PositionSource', () {
    final PositionSource source = GpsNmeaSimulatorService();
    expect(source.positions, isA<Stream<PositionFix>>());
    (source as GpsNmeaSimulatorService).dispose();
  });
}
