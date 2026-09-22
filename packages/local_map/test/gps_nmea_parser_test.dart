import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';

/// Regressionstest fuer die NMEA-Koordinatenumrechnung.
///
/// Der Minutenanteil ist bei Breite (ddmm.mmmm) und Laenge (dddmm.mmmm)
/// immer zweistellig. Ein Teiler von 1000 fuer die Laenge ergab aus
/// `00921.8766` faelschlich 15,36 statt 9,36 Grad - die Kamera sprang damit
/// aus dem Abdeckungsbereich der MBTiles heraus und die Karte blieb leer.
void main() {
  Future<List<SimulatedGpsFix>> parse(List<String> lines) async {
    final sim = GpsNmeaSimulatorService();
    final collected = <SimulatedGpsFix>[];
    final sub = sim.fixes.listen(collected.add);
    sim.loadFromLines(lines);
    sim.start(interval: const Duration(milliseconds: 1), loop: false);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    sim.stop();
    await sub.cancel();
    sim.dispose();
    return collected;
  }

  test('GGA: dreistellige Laengengrade werden korrekt umgerechnet', () async {
    final fixes = await parse([
      r'$GPGGA,140906.149,5024.5978,N,00921.8766,E,1,08,,372.6,M,48.0,M,,0000*7C',
    ]);

    expect(fixes, hasLength(1));
    expect(fixes.first.position.latitude, closeTo(50.40996, 0.0001));
    expect(fixes.first.position.longitude, closeTo(9.36461, 0.0001));
  });

  test('RMC: Breite und Laenge stimmen, Hemisphaeren kehren um', () async {
    final fixes = await parse([
      r'$GPRMC,140906.00,A,5024.5978,S,00921.8766,W,0.0,0.0,210425,,,A*7C',
    ]);

    expect(fixes, hasLength(1));
    expect(fixes.first.position.latitude, closeTo(-50.40996, 0.0001));
    expect(fixes.first.position.longitude, closeTo(-9.36461, 0.0001));
  });

  test('GGA ohne gueltigen Fix wird verworfen', () {
    final sim = GpsNmeaSimulatorService();
    final loaded = sim.loadFromLines([
      r'$GPGGA,140906.149,5024.5978,N,00921.8766,E,0,00,,372.6,M,48.0,M,,0000*7C',
    ]);

    expect(loaded, 0);
    expect(sim.hasData, isFalse);
    sim.dispose();
  });

  test('unplausible Koordinaten werden verworfen', () {
    final sim = GpsNmeaSimulatorService();
    final loaded = sim.loadFromLines([
      // 99 Minuten gibt es nicht
      r'$GPGGA,140906.149,5099.0000,N,00921.8766,E,1,08,,372.6,M,48.0,M,,0000*7C',
    ]);

    expect(loaded, 0);
    sim.dispose();
  });
}
