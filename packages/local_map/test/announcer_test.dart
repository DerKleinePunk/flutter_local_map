import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';

/// Eine L-foermige Route: 1 km nach Norden, dann 1 km nach Osten, mit den
/// Sprechtexten, wie Valhalla sie liefert.
RoutingResult _route({bool verbal = true}) => RoutingResult(
  geometry: const [
    RoutingPoint(lat: 50.000, lon: 9.000),
    RoutingPoint(lat: 50.0045, lon: 9.000),
    RoutingPoint(lat: 50.009, lon: 9.000), // Ecke, Index 2
    RoutingPoint(lat: 50.009, lon: 9.007),
    RoutingPoint(lat: 50.009, lon: 9.014), // Ziel, Index 4
  ],
  distanceMeters: 2000,
  durationSeconds: 200,
  maneuvers: [
    RoutingManeuver(
      instruction: 'Auf Kirchplatz Richtung Norden fahren.',
      lengthKm: 1,
      timeSeconds: 100,
      type: 1,
      beginShapeIndex: 0,
      verbalPre: verbal ? 'Auf Kirchplatz Richtung Norden fahren.' : null,
    ),
    RoutingManeuver(
      instruction: 'Rechts auf Amthof abbiegen.',
      lengthKm: 1,
      timeSeconds: 100,
      type: 10,
      beginShapeIndex: 2,
      verbalAlert: verbal ? 'Rechts auf Amthof abbiegen.' : null,
      verbalPre: verbal ? 'Rechts auf Amthof abbiegen. Dann das Ziel.' : null,
      verbalPost: verbal ? '1 Kilometer weiter auf Amthof.' : null,
    ),
    RoutingManeuver(
      instruction: 'Ziel erreicht.',
      lengthKm: 0,
      timeSeconds: 0,
      type: 4,
      beginShapeIndex: 4,
      verbalAlert: verbal ? 'Sie erreichen Ihr Ziel.' : null,
      verbalPre: verbal ? 'Sie haben Ihr Ziel erreicht.' : null,
    ),
  ],
);

const double _mPerDegLat = 111319.49;
final double _mPerDegLon = 111319.49 * 0.64279; // cos(50 Grad)

/// Punkt [traveled] Meter entlang der L-Route (Ecke bei 1000 m).
LatLng _at(double traveled) => traveled <= 1000
    ? LatLng(50 + traveled / _mPerDegLat, 9)
    : LatLng(50.009, 9 + (traveled - 1000) / _mPerDegLon);

/// Faehrt die Route mit [speed] m/s in 1-s-Schritten ab [from] bis [to] und
/// sammelt alle Ereignisse.
List<AnnouncementEvent> _drive({
  double from = 0,
  double to = 2010,
  double speed = 10,
  AnnouncementPolicy policy = const AnnouncementPolicy(),
  RoutingResult? route,
  List<double>? positions,
}) {
  final r = route ?? _route();
  final tracker = RouteTracker(r);
  final announcer = ManeuverAnnouncer(r, policy);
  final events = <AnnouncementEvent>[];
  final points =
      positions ??
      [for (var d = from; d <= to; d += speed == 0 ? 10 : speed) d];
  for (final d in points) {
    final p = tracker.update(
      _at(d),
      headingDegrees: d <= 1000 ? 0 : 90,
      speedMps: speed,
    );
    if (p == null) continue;
    events.addAll(announcer.update(p, speedMps: speed, offRoute: p.offRoute));
  }
  return events;
}

List<String> _spoken(List<AnnouncementEvent> events) => [
  for (final e in events)
    if (e is Announcement) e.text,
];

/// Jede Ansage stand vorher wortgleich in einem Prepare.
void _expectPrepared(List<AnnouncementEvent> events) {
  final prepared = <String>{};
  for (final e in events) {
    switch (e) {
      case AnnouncementPrepare(:final texts):
        prepared.addAll(texts);
      case Announcement(:final text):
        expect(prepared, contains(text), reason: 'nicht vorbereitet: $text');
    }
  }
}

void main() {
  test('Stadtfahrt: Start, 300 m, jetzt, Ziel - jede Ansage genau einmal', () {
    final events = _drive();
    expect(_spoken(events), [
      'Auf Kirchplatz Richtung Norden fahren.',
      'In 300 Metern rechts auf Amthof abbiegen.',
      'Rechts auf Amthof abbiegen. Dann das Ziel.',
      'In 300 Metern Sie erreichen Ihr Ziel.',
      'Sie haben Ihr Ziel erreicht.',
    ]);
    _expectPrepared(events);
  });

  test('Prepare kommt, sobald ein Manoever das naechste wird', () {
    final events = _drive(to: 1100);
    final prepares = events.whereType<AnnouncementPrepare>().toList();
    expect(prepares, hasLength(3));
    expect(
      prepares[1].texts,
      containsAll([
        'In 1 Kilometer rechts auf Amthof abbiegen.',
        'In 400 Metern rechts auf Amthof abbiegen.',
        'In 300 Metern rechts auf Amthof abbiegen.',
        'Rechts auf Amthof abbiegen. Dann das Ziel.',
        'Die Route wird neu berechnet.',
      ]),
    );
  });

  test('Autobahntempo: 1 km und 400 m statt 300 m', () {
    final events = _drive(speed: 30);
    final spoken = _spoken(events);
    expect(spoken, contains('In 1 Kilometer rechts auf Amthof abbiegen.'));
    expect(spoken, contains('In 400 Metern rechts auf Amthof abbiegen.'));
    expect(
      spoken,
      isNot(contains('In 300 Metern rechts auf Amthof abbiegen.')),
    );
    // "Jetzt" bei 3 s Fahrt = 90 m vorher.
    expect(spoken, contains('Rechts auf Amthof abbiegen. Dann das Ziel.'));
    _expectPrepared(events);
  });

  test('spaet dazugekommen: keine Stufe, die nicht mehr stimmt', () {
    // Route erst 100 m vor der Ecke: "In 300 Metern" waere falsch.
    final spoken = _spoken(_drive(from: 900, to: 1050));
    expect(spoken, ['Rechts auf Amthof abbiegen. Dann das Ziel.']);
  });

  test('im Stand wird nichts gesagt, Prepare kommt trotzdem', () {
    final events = _drive(speed: 0, positions: [750, 750, 750, 980, 980]);
    expect(_spoken(events), isEmpty);
    expect(events.whereType<AnnouncementPrepare>(), isNotEmpty);
  });

  test('GPS-Sprung zurueck: keine Wiederholung', () {
    final spoken = _spoken(
      _drive(positions: [600, 650, 710, 720, 660, 720, 730, 740]),
    );
    expect(
      spoken.where((t) => t.startsWith('In 300 Metern rechts')),
      hasLength(1),
    );
  });

  test('nach dem Ziel ist Schluss', () {
    final spoken = _spoken(
      _drive(positions: [1900, 1960, 1990, 2000, 2000, 1990, 2000]),
    );
    expect(
      spoken.where((t) => t == 'Sie haben Ihr Ziel erreicht.'),
      hasLength(1),
    );
  });

  test('ohne Sprechtexte gilt instruction', () {
    final spoken = _spoken(_drive(route: _route(verbal: false), to: 1050));
    expect(spoken, contains('In 300 Metern rechts auf Amthof abbiegen.'));
    expect(spoken, contains('Rechts auf Amthof abbiegen.'));
  });

  test('abgeschaltet: kein einziges Ereignis', () {
    expect(_drive(policy: const AnnouncementPolicy(enabled: false)), isEmpty);
  });

  test('Satz nach dem Manoever nur, wenn eingeschaltet', () {
    expect(
      _spoken(_drive()),
      isNot(contains('1 Kilometer weiter auf Amthof.')),
    );
    final events = _drive(policy: const AnnouncementPolicy(announcePost: true));
    expect(_spoken(events), contains('1 Kilometer weiter auf Amthof.'));
    _expectPrepared(events);
  });

  test('englische Vorsaetze', () {
    final spoken = _spoken(
      _drive(
        to: 1050,
        policy: AnnouncementPolicy(texts: AnnouncementTexts.english),
        route: RoutingResult(
          geometry: _route().geometry,
          distanceMeters: 2000,
          durationSeconds: 200,
          maneuvers: [
            _route().maneuvers[0],
            const RoutingManeuver(
              instruction: 'Turn right onto Amthof.',
              lengthKm: 1,
              timeSeconds: 100,
              type: 10,
              beginShapeIndex: 2,
              verbalAlert: 'Turn right onto Amthof.',
            ),
            _route().maneuvers[2],
          ],
        ),
      ),
    );
    expect(spoken, contains('In 300 meters, turn right onto Amthof.'));
  });

  test('neben der Route keine Manoeveransagen', () {
    final r = _route();
    final tracker = RouteTracker(r);
    final announcer = ManeuverAnnouncer(r);
    final events = <AnnouncementEvent>[];
    for (final d in <double>[600, 650, 700, 710, 720, 730, 740, 750]) {
      // 200 m oestlich der Route, also verlassen.
      final p = tracker.update(
        LatLng(_at(d).latitude, 9 + 200 / _mPerDegLon),
        headingDegrees: 0,
        speedMps: 10,
      )!;
      events.addAll(announcer.update(p, speedMps: 10, offRoute: p.offRoute));
    }
    // "In 300 Metern" waere beim dritten Fix faellig - genau dann, wenn die
    // Route als verlassen gilt.
    expect(_spoken(events).where((t) => t.contains('Amthof')), isEmpty);
  });
}
