import 'dart:async';

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
}
