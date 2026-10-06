import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';

class _FakeRouting implements RoutingProvider {
  final requests = <(LatLng?, LatLng)>[];
  final pending = <Completer<RoutingResult>>[];

  @override
  Future<RoutingResult> route({LatLng? start, required LatLng end}) {
    requests.add((start, end));
    final c = Completer<RoutingResult>();
    pending.add(c);
    return c.future;
  }

  @override
  Future<bool> isAvailable() async => true;
}

class _FakePositions implements PositionSource {
  final controller = StreamController<PositionFix>.broadcast();

  @override
  Stream<PositionFix> get positions => controller.stream;
}

class _FakeReverse implements ReverseGeocoder {
  final asked = <LatLng>[];

  @override
  Future<LocationName?> nameAt(LatLng position) async {
    asked.add(position);
    return LocationName(street: 'Strasse ${asked.length}');
  }
}

GeocoderResult _place(String name, double lat, double lon) => GeocoderResult(
  name: name,
  location: LatLng(lat, lon),
  zoom: 14,
  type: 'place',
);

RoutingResult _result(double km) => RoutingResult(
  geometry: const [
    RoutingPoint(lat: 50, lon: 9),
    RoutingPoint(lat: 50.1, lon: 9.1),
  ],
  distanceMeters: km * 1000,
  durationSeconds: 60,
  maneuvers: const [],
);

void main() {
  test('Route mit Start und Ziel, Punkte fuer die Karte', () async {
    final routing = _FakeRouting();
    final map = LocalMapController(routingProvider: routing);
    addTearDown(map.dispose);

    await map.setStart(_place('Alsfeld', 50.75, 9.27));
    expect(routing.requests, isEmpty, reason: 'ohne Ziel keine Anfrage');
    expect(map.route, isNull);

    final done = map.setDestination(_place('Fulda', 50.55, 9.68));
    expect(map.isRouting, isTrue);
    expect(routing.requests, hasLength(1));

    routing.pending.single.complete(_result(40));
    await done;

    expect(map.isRouting, isFalse);
    expect(map.route?.distanceMeters, 40000);
    expect(map.routePoints, hasLength(2));
    expect(map.routingAvailable, isTrue);
  });

  test('eine veraltete Antwort ueberschreibt die neuere nicht', () async {
    final routing = _FakeRouting();
    final map = LocalMapController(routingProvider: routing);
    addTearDown(map.dispose);

    await map.setStart(_place('A', 50, 9));
    final first = map.setDestination(_place('B', 50.1, 9.1));
    final second = map.setDestination(_place('C', 50.2, 9.2));

    // Die neuere kommt zuerst zurueck, die alte danach.
    routing.pending[1].complete(_result(20));
    await second;
    routing.pending[0].complete(_result(10));
    await first;

    expect(map.route?.distanceMeters, 20000);
    expect(map.isRouting, isFalse);
  });

  test('Fehler landen in routingError, die Route verschwindet', () async {
    final routing = _FakeRouting();
    final map = LocalMapController(routingProvider: routing);
    addTearDown(map.dispose);

    await map.setStart(_place('A', 50, 9));
    final done = map.setDestination(_place('B', 50.1, 9.1));
    routing.pending.single.completeError(const RoutingException('kaputt'));
    await done;

    expect(map.route, isNull);
    expect(map.routingError, 'kaputt');
  });

  test('Ziel loeschen entfernt die Route', () async {
    final routing = _FakeRouting();
    final map = LocalMapController(routingProvider: routing);
    addTearDown(map.dispose);

    await map.setStart(_place('A', 50, 9));
    final done = map.setDestination(_place('B', 50.1, 9.1));
    routing.pending.single.complete(_result(5));
    await done;
    await map.setDestination(null);

    expect(map.route, isNull);
    expect(map.routePoints, isEmpty);
  });

  test('ohne RoutingProvider kein Routing und nicht verfuegbar', () async {
    final map = LocalMapController();
    addTearDown(map.dispose);

    await map.setStart(_place('A', 50, 9));
    await map.setDestination(_place('B', 50.1, 9.1));

    expect(map.route, isNull);
    expect(await map.checkRoutingAvailability(), isFalse);
  });

  test('Positionen der Quelle kommen im Controller an', () async {
    final source = _FakePositions();
    final map = LocalMapController(positionSource: source);
    var notified = 0;
    map.addListener(() => notified++);

    source.controller.add(
      const PositionFix(position: LatLng(50, 9), headingDegrees: 90),
    );
    await Future<void>.delayed(Duration.zero);

    expect(map.position?.headingDegrees, 90);
    expect(notified, 1);

    map.dispose();
    // Nach dispose haengt der Controller nicht mehr an der Quelle.
    expect(source.controller.hasListener, isFalse);
  });

  test('ohne Route wird die Position benannt, erst nach 25 m neu', () async {
    final source = _FakePositions();
    final reverse = _FakeReverse();
    final map = LocalMapController(
      positionSource: source,
      reverseGeocoder: reverse,
    );
    addTearDown(map.dispose);

    Future<void> drive(double lat) async {
      source.controller.add(PositionFix(position: LatLng(lat, 9)));
      await Future<void>.delayed(Duration.zero);
    }

    await drive(50);
    expect(map.locationName?.street, 'Strasse 1');
    await drive(50.0001); // ~11 m
    expect(reverse.asked, hasLength(1));
    await drive(50.0004); // ~44 m vom letzten Namen
    expect(reverse.asked, hasLength(2));
    expect(map.locationName?.street, 'Strasse 2');
  });

  test('mit Route ruht die Standortanzeige', () async {
    final source = _FakePositions();
    final reverse = _FakeReverse();
    final map = LocalMapController(
      positionSource: source,
      reverseGeocoder: reverse,
    );
    addTearDown(map.dispose);

    source.controller.add(const PositionFix(position: LatLng(50, 9)));
    await Future<void>.delayed(Duration.zero);
    expect(map.locationName, isNotNull);

    map.setRoute(_result(10));
    expect(map.locationName, isNull);
    source.controller.add(const PositionFix(position: LatLng(50.01, 9)));
    await Future<void>.delayed(Duration.zero);
    expect(reverse.asked, hasLength(1), reason: 'mit Route keine Anfrage');

    // Route weg: sofort neu benennen, ohne erst 25 m zu fahren.
    map.setRoute(null);
    await Future<void>.delayed(Duration.zero);
    expect(reverse.asked, hasLength(2));
    expect(map.locationName, isNotNull);
  });

  test('mit Route und Position gibt es Fortschritt', () async {
    final routing = _FakeRouting();
    final source = _FakePositions();
    final map = LocalMapController(
      routingProvider: routing,
      positionSource: source,
    );
    addTearDown(map.dispose);

    await map.setStart(_place('A', 50, 9));
    final done = map.setDestination(_place('B', 50.1, 9.1));
    routing.pending.single.complete(_result(13));
    await done;
    expect(map.progress, isNull, reason: 'noch keine Position');

    source.controller.add(
      const PositionFix(
        position: LatLng(50.05, 9.05),
        headingDegrees: 40,
        speedMps: 15,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final progress = map.progress!;
    expect(progress.distanceToRouteMeters, lessThan(5));
    expect(progress.remainingMeters, closeTo(progress.traveledMeters, 50));
    expect(map.heading, 40);
  });

  test('Suche und neue Route beenden den Folgemodus', () async {
    final routing = _FakeRouting();
    final map = LocalMapController(routingProvider: routing);
    addTearDown(map.dispose);

    expect(map.followPosition, isTrue);
    map.showPlace(_place('A', 50, 9));
    expect(map.followPosition, isFalse);

    map.followPosition = true;
    await map.setStart(_place('A', 50, 9));
    final done = map.setDestination(_place('B', 50.1, 9.1));
    routing.pending.single.complete(_result(13));
    await done;
    expect(map.followPosition, isFalse);
  });

  test('Fahrtrichtung oben laesst sich schalten', () {
    final map = LocalMapController();
    addTearDown(map.dispose);
    var notified = 0;
    map.addListener(() => notified++);

    expect(map.headingUp, isFalse);
    map.headingUp = true;
    map.headingUp = true;
    expect(map.headingUp, isTrue);
    expect(notified, 1);
  });

  test(
    'setRoute setzt eine fertige Route und schlaegt laufende Anfragen',
    () async {
      final routing = _FakeRouting();
      final map = LocalMapController(routingProvider: routing);
      addTearDown(map.dispose);

      await map.setStart(_place('A', 50, 9));
      final pending = map.setDestination(_place('B', 50.1, 9.1));
      map.setRoute(_result(45));
      // Die alte Anfrage kommt danach zurueck und darf nichts aendern.
      routing.pending.single.complete(_result(1));
      await pending;

      expect(map.route?.distanceMeters, 45000);
      expect(map.isRouting, isFalse);
      expect(map.start, isNull);

      map.setRoute(null);
      expect(map.route, isNull);
    },
  );

  test('ohne Start faehrt die Route von der eigenen Position los', () async {
    final routing = _FakeRouting();
    final source = _FakePositions();
    final map = LocalMapController(
      routingProvider: routing,
      positionSource: source,
    );
    addTearDown(map.dispose);

    // Noch keine Position: der Anbieter bekommt keinen Start und entscheidet.
    final first = map.setDestination(_place('Fulda', 50.55, 9.68));
    expect(routing.requests.single.$1, isNull);
    routing.pending.single.complete(_result(40));
    await first;

    source.controller.add(const PositionFix(position: LatLng(50.7, 9.2)));
    await Future<void>.delayed(Duration.zero);
    final second = map.setDestination(_place('Fulda', 50.55, 9.68));
    expect(routing.requests.last.$1, const LatLng(50.7, 9.2));
    routing.pending.last.complete(_result(41));
    await second;
    expect(map.route?.distanceMeters, 41000);
  });

  group('Abweichen von der Route', () {
    // Gerade Route 2 km nach Norden, Ziel am Ende.
    const north = RoutingResult(
      geometry: [
        RoutingPoint(lat: 50.000, lon: 9.000),
        RoutingPoint(lat: 50.018, lon: 9.000),
      ],
      distanceMeters: 2000,
      durationSeconds: 200,
      maneuvers: [],
    );
    final ziel = _place('Ziel', 50.018, 9.0);

    // 0,0012 Grad Laenge sind auf 50 Grad Breite etwa 86 m.
    PositionFix fix(int i, {double east = 0, double speed = 10}) => PositionFix(
      position: LatLng(50.002 + i * 0.0001, 9 + east),
      headingDegrees: east == 0 ? 0 : 90,
      speedMps: speed,
    );

    late _FakeRouting routing;
    late _FakePositions source;
    late DateTime now;
    late LocalMapController map;
    late List<bool> changes;

    Future<void> send(PositionFix f) async {
      source.controller.add(f);
      await Future<void>.delayed(Duration.zero);
    }

    /// Drei Fixes daneben: danach gilt die Route als verlassen.
    Future<void> leave(int from) async {
      for (var i = from; i < from + 3; i++) {
        await send(fix(i, east: 0.0012));
      }
    }

    setUp(() async {
      routing = _FakeRouting();
      source = _FakePositions();
      now = DateTime.utc(2026, 10, 6, 8);
      map = LocalMapController(
        routingProvider: routing,
        positionSource: source,
        clock: () => now,
      );
      changes = <bool>[];
      map.offRouteChanges.listen(changes.add);
      await send(fix(0));
      final done = map.setDestination(ziel);
      routing.pending.single.complete(north);
      await done;
      map.followPosition = true;
    });

    tearDown(() => map.dispose());

    test(
      'verlassen: genau eine Neuberechnung ab der Position zum Ziel',
      () async {
        await send(fix(1));
        await send(fix(2, east: 0.0012));
        await send(fix(3, east: 0.0012));
        expect(map.offRoute, isFalse);
        expect(routing.requests, hasLength(1));

        await send(fix(4, east: 0.0012));
        expect(map.offRoute, isTrue);
        expect(map.isRerouting, isTrue);
        expect(routing.requests, hasLength(2));
        expect(routing.requests.last.$1, fix(4, east: 0.0012).position);
        expect(routing.requests.last.$2, ziel.location);

        // Weitere Fixes daneben, waehrend gerechnet wird: keine zweite Anfrage.
        await send(fix(5, east: 0.0012));
        expect(routing.requests, hasLength(2));

        // Die neue Route beginnt an der Position.
        routing.pending.last.complete(
          RoutingResult(
            geometry: [
              RoutingPoint.fromLatLng(fix(5, east: 0.0012).position),
              const RoutingPoint(lat: 50.018, lon: 9.0),
            ],
            distanceMeters: 1700,
            durationSeconds: 170,
            maneuvers: const [],
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(map.isRerouting, isFalse);
        expect(map.rerouteCount, 1);
        expect(map.route?.distanceMeters, 1700);
        expect(map.offRoute, isFalse);
        expect(changes, [true, false]);
        expect(map.followPosition, isTrue, reason: 'Kamera bleibt beim Fahrer');
        expect(map.destination, ziel);
      },
    );

    test(
      'Route aus setRoute (Replay): Anzeige ja, Neuberechnung nein',
      () async {
        // Mit Ziel fuer die Markierung - neu berechnet wird trotzdem nicht.
        map.setRoute(north, destination: ziel);
        await leave(1);
        await send(fix(4, east: 0.0012));
        expect(map.offRoute, isTrue);
        expect(routing.requests, hasLength(1));
      },
    );

    test('im Stand wird nicht neu berechnet', () async {
      await leave(1);
      expect(routing.requests, hasLength(2));
      routing.pending.last.completeError(const RoutingException('weg'));
      await Future<void>.delayed(Duration.zero);

      now = now.add(const Duration(minutes: 5));
      await send(fix(4, east: 0.0012, speed: 0));
      expect(routing.requests, hasLength(2));
    });

    test('Fehler: alte Route bleibt, dann 30 s, danach 60 s Abstand', () async {
      final logs = <String>[];
      final oldPrint = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
      addTearDown(() => debugPrint = oldPrint);

      await leave(1);
      expect(routing.requests, hasLength(2));
      routing.pending.last.completeError(const RoutingException('weg'));
      await Future<void>.delayed(Duration.zero);

      final times = <int>[];
      final start = now;
      for (var s = 1; s <= 200; s++) {
        now = start.add(Duration(seconds: s));
        final before = routing.requests.length;
        // Hin und her auf demselben Stueck, nie bis zum Ziel.
        await send(fix(4 + s % 10, east: 0.0012));
        if (routing.requests.length > before) {
          times.add(s);
          routing.pending.last.completeError(const RoutingException('weg'));
          await Future<void>.delayed(Duration.zero);
        }
      }
      // Die erste Anfrage kam beim dritten Fix daneben (s = 0).
      expect(times, [30, 90, 150]);
      expect(map.route, north);
      expect(map.rerouteError, 'weg');
      expect(map.offRoute, isTrue);
      expect(
        logs.where((l) => l.contains('Neuberechnung fehlgeschlagen')),
        hasLength(1),
      );
    });

    test('abgeschaltet per OffRoutePolicy', () async {
      final quiet = LocalMapController(
        routingProvider: routing,
        positionSource: source,
        offRoutePolicy: const OffRoutePolicy(reroute: false),
      );
      addTearDown(quiet.dispose);
      final done = quiet.setDestination(ziel);
      routing.pending.last.complete(north);
      await done;
      final before = routing.requests.length;

      await leave(1);
      expect(quiet.offRoute, isTrue);
      // map (setUp) rechnet neu, quiet nicht.
      expect(routing.requests.length, before + 1);
    });
  });
}
