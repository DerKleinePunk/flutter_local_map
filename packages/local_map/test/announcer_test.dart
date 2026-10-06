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

/// Dieselbe L-Form, aber nach der Ecke folgen die Manoever dicht: 200 m,
/// dann 150 m, dann 650 m bis zum Ziel.
RoutingResult _denseRoute() => RoutingResult(
  geometry: [
    const RoutingPoint(lat: 50.000, lon: 9.000),
    const RoutingPoint(lat: 50.0045, lon: 9.000),
    const RoutingPoint(lat: 50.009, lon: 9.000), // Ecke, 1000 m
    RoutingPoint(lat: 50.009, lon: 9 + 200 / _mPerDegLon), // 1200 m
    RoutingPoint(lat: 50.009, lon: 9 + 350 / _mPerDegLon), // 1350 m
    RoutingPoint(lat: 50.009, lon: 9 + 1000 / _mPerDegLon), // Ziel
  ],
  distanceMeters: 2000,
  durationSeconds: 200,
  maneuvers: [
    _route().maneuvers[0],
    const RoutingManeuver(
      instruction: 'Rechts auf Amthof abbiegen.',
      lengthKm: 0.2,
      timeSeconds: 20,
      type: 10,
      beginShapeIndex: 2,
    ),
    const RoutingManeuver(
      instruction: 'Links auf Bahnhofstrasse abbiegen.',
      lengthKm: 0.15,
      timeSeconds: 15,
      type: 15,
      beginShapeIndex: 3,
    ),
    const RoutingManeuver(
      instruction: 'Rechts auf L 3195 abbiegen.',
      lengthKm: 0.65,
      timeSeconds: 65,
      type: 10,
      beginShapeIndex: 4,
    ),
    const RoutingManeuver(
      instruction: 'Ziel erreicht.',
      lengthKm: 0,
      timeSeconds: 0,
      type: 4,
      beginShapeIndex: 5,
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
  List<double>? speeds,
}) {
  final r = route ?? _route();
  final tracker = RouteTracker(r);
  final announcer = ManeuverAnnouncer(r, policy);
  final events = <AnnouncementEvent>[];
  final points =
      positions ??
      [for (var d = from; d <= to; d += speed == 0 ? 10 : speed) d];
  for (var i = 0; i < points.length; i++) {
    final d = points[i];
    final v = speeds == null ? speed : speeds[i];
    final p = tracker.update(
      _at(d),
      headingDegrees: d <= 1000 ? 0 : 90,
      speedMps: v,
    );
    if (p == null) continue;
    events.addAll(announcer.update(p, speedMps: v, offRoute: p.offRoute));
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
      'In 300 Metern erreichen Sie Ihr Ziel.',
      'Sie haben Ihr Ziel erreicht.',
    ]);
    _expectPrepared(events);
  });

  test('Prepare: nur die Stufen des Tempos, in Sprechreihenfolge', () {
    final events = _drive(to: 1100);
    final prepares = events.whereType<AnnouncementPrepare>().toList();
    expect(prepares, hasLength(3));
    expect(prepares[1].texts, [
      'In 300 Metern rechts auf Amthof abbiegen.',
      'Rechts auf Amthof abbiegen. Dann das Ziel.',
      'Die Route wird neu berechnet.',
    ]);

    final fast = _drive(
      to: 1100,
      speed: 30,
    ).whereType<AnnouncementPrepare>().toList();
    expect(fast[1].texts, [
      'In 1 Kilometer rechts auf Amthof abbiegen.',
      'In 400 Metern rechts auf Amthof abbiegen.',
      'Rechts auf Amthof abbiegen. Dann das Ziel.',
      'Die Route wird neu berechnet.',
    ]);
  });

  test('Tempoklasse wechselt: neues Prepare, Ansage war vorbereitet', () {
    // Bis 300 m Landstrasse, dann schnell: 400 m ist vorbei, 300 m gilt
    // nicht mehr - aber "jetzt" und die Ziel-Stufen passen.
    final positions = <double>[0, 100, 200, 300, 330, 360, 390];
    final speeds = <double>[10, 10, 10, 10, 30, 30, 30];
    final events = _drive(positions: positions, speeds: speeds);
    final prepares = events.whereType<AnnouncementPrepare>().toList();
    expect(prepares, hasLength(3), reason: 'Start, Manoever 1, Wechsel');
    expect(
      prepares.last.texts.first,
      'In 1 Kilometer rechts auf Amthof abbiegen.',
    );
    _expectPrepared(
      _drive(
        positions: [
          0,
          100,
          200,
          300,
          400,
          500,
          600,
          650,
          700,
          750,
          800,
          900,
          980,
        ],
        speeds: [10, 10, 10, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
      ),
    );
  });

  test('Hysterese: um 80 km/h kein Hin und Her', () {
    final positions = <double>[for (var d = 0.0; d < 500; d += 22) d];
    final speeds = <double>[
      for (var i = 0; i < positions.length; i++) i.isEven ? 22.5 : 21.5,
    ];
    final prepares = _drive(
      positions: positions,
      speeds: speeds,
    ).whereType<AnnouncementPrepare>().toList();
    // Start, Manoever 1 - und hoechstens ein Wechsel.
    expect(prepares.length, lessThanOrEqualTo(3));
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

  test('Aufzeichnung beginnt nach dem Ziel von vorn: nichts mehr', () {
    final events = _drive(
      positions: [1900, 1960, 1990, 2000, 0, 10, 20, 30, 700, 710, 720],
    );
    final spoken = _spoken(events);
    expect(spoken.last, 'Sie haben Ihr Ziel erreicht.');
    expect(events.last, isA<Announcement>());
  });

  test('zurueck vor ein schon angesagtes Manoever: keine Wiederholung', () {
    // Ecke bei 1000 m ist angesagt und passiert, dann springt das GPS 150 m
    // zurueck vor die Ecke.
    final spoken = _spoken(
      _drive(
        positions: [960, 980, 1000, 1020, 1040, 850, 900, 950, 980, 1000, 1050],
      ),
    );
    expect(
      spoken.where((t) => t.startsWith('Rechts auf Amthof')),
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

  group('Vorausschau', () {
    test(
      'Prepare nennt die dichten Manoever dahinter, das naechste zuerst',
      () {
        final prepares = _drive(
          route: _denseRoute(),
          to: 900,
        ).whereType<AnnouncementPrepare>().toList();
        expect(prepares, hasLength(2));
        expect(prepares[1].texts, [
          'In 300 Metern rechts auf Amthof abbiegen.',
          'Rechts auf Amthof abbiegen.',
          // 200 m hinter der Ecke: Die 300-m-Stufe kommt noch (ab 180 m).
          'In 300 Metern links auf Bahnhofstrasse abbiegen.',
          'Links auf Bahnhofstrasse abbiegen.',
          // 150 m dahinter: keine Stufe mehr, nur "jetzt".
          'Rechts auf L 3195 abbiegen.',
          'Die Route wird neu berechnet.',
        ]);
      },
    );

    test('hoechstens 500 m und 2 Manoever', () {
      final r = _denseRoute();
      final announcer = ManeuverAnnouncer(r);
      // Ab der Ecke: 200 + 150 = 350 m bis L 3195; das Ziel liegt 1000 m
      // dahinter.
      expect(announcer.textsFor(1), isNot(contains('Ziel erreicht.')));
      final one = ManeuverAnnouncer(
        r,
        const AnnouncementPolicy(lookaheadManeuvers: 1),
      );
      expect(one.textsFor(1), isNot(contains('Rechts auf L 3195 abbiegen.')));
      expect(one.textsFor(1), contains('Links auf Bahnhofstrasse abbiegen.'));
      final near = ManeuverAnnouncer(
        r,
        const AnnouncementPolicy(lookaheadMeters: 300),
      );
      expect(
        near.textsFor(1),
        isNot(contains('Rechts auf L 3195 abbiegen.')),
        reason: '350 m hinter der Ecke',
      );
      final off = ManeuverAnnouncer(
        r,
        const AnnouncementPolicy(lookaheadMeters: 0),
      );
      expect(off.textsFor(1), [
        'In 300 Metern rechts auf Amthof abbiegen.',
        'Rechts auf Amthof abbiegen.',
        'Die Route wird neu berechnet.',
      ]);
    });

    test('dichte Fahrt: jede Ansage war schon ein Manoever vorher dran', () {
      final events = _drive(route: _denseRoute());
      expect(_spoken(events), [
        'Auf Kirchplatz Richtung Norden fahren.',
        'In 300 Metern rechts auf Amthof abbiegen.',
        'Rechts auf Amthof abbiegen.',
        'In 300 Metern links auf Bahnhofstrasse abbiegen.',
        'Links auf Bahnhofstrasse abbiegen.',
        'Rechts auf L 3195 abbiegen.',
        'In 300 Metern erreichen Sie Ihr Ziel.',
        'Ziel erreicht.',
      ]);
      _expectPrepared(events);
      // Was nach der Ecke gesagt wird, stand schon im Prepare vor der Ecke.
      final beforeCorner = events
          .whereType<AnnouncementPrepare>()
          .elementAt(1)
          .texts;
      for (final t in _spoken(events).sublist(3, 6)) {
        expect(beforeCorner, contains(t));
      }
    });
  });
}
