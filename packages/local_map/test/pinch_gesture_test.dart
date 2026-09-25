import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Nachbau der Kartenkonfiguration, mit der die App auf dem Pi laeuft:
/// Braunschweig-Ausschnitt, Kamera an dessen Grenzen gebunden, Zoom 11.
final _braunschweig = LatLngBounds(
  const LatLng(52.12, 10.28),
  const LatLng(52.42, 10.78),
);

Widget _buildMap(MapController controller, {required InteractionOptions io}) {
  return MaterialApp(
    home: Scaffold(
      body: FlutterMap(
        mapController: controller,
        options: MapOptions(
          initialCenter: _braunschweig.center,
          initialZoom: 11,
          minZoom: 9.49,
          maxZoom: 17,
          cameraConstraint: CameraConstraint.containCenter(
            bounds: _braunschweig,
          ),
          interactionOptions: io,
        ),
        children: const [],
      ),
    ),
  );
}

/// Zwei Finger, die sich voneinander weg bewegen - also hineinzoomen.
Future<void> _pinchOpen(WidgetTester tester) async {
  final centre = tester.getCenter(find.byType(FlutterMap));
  final a = await tester.startGesture(centre - const Offset(40, 0));
  final b = await tester.startGesture(centre + const Offset(40, 0));
  await tester.pump(const Duration(milliseconds: 16));

  for (var i = 0; i < 10; i++) {
    await a.moveBy(const Offset(-8, 0));
    await b.moveBy(const Offset(8, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }

  await a.up();
  await b.up();
  await tester.pumpAndSettle();
}

/// Wie im echten Betrieb: der zweite Finger landet ein paar Frames spaeter,
/// und der erste hat sich bis dahin schon bewegt.
Future<void> _pinchOpenStaggered(
  WidgetTester tester, {
  Offset offsetFromCentre = Offset.zero,
}) async {
  final centre = tester.getCenter(find.byType(FlutterMap)) + offsetFromCentre;

  final a = await tester.startGesture(centre - const Offset(40, 0));
  await tester.pump(const Duration(milliseconds: 16));
  // Der erste Finger rutscht ein wenig, bevor der zweite aufsetzt.
  for (var i = 0; i < 3; i++) {
    await a.moveBy(const Offset(-3, 2));
    await tester.pump(const Duration(milliseconds: 16));
  }

  final b = await tester.startGesture(centre + const Offset(40, 0));
  await tester.pump(const Duration(milliseconds: 16));

  for (var i = 0; i < 10; i++) {
    await a.moveBy(const Offset(-8, 0));
    await b.moveBy(const Offset(8, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }

  // Auch das Abheben passiert nacheinander.
  await a.up();
  await tester.pump(const Duration(milliseconds: 16));
  await b.up();
  await tester.pumpAndSettle();
}

double _metres(LatLng a, LatLng b) =>
    const Distance().as(LengthUnit.Meter, a, b);

void main() {
  testWidgets('Kneifgeste zoomt hinein, ohne die Karte wegzuschieben', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = MapController();
    await tester.pumpWidget(
      _buildMap(controller, io: const InteractionOptions()),
    );
    await tester.pumpAndSettle();

    final startCenter = controller.camera.center;
    final startZoom = controller.camera.zoom;

    await _pinchOpen(tester);

    final endCenter = controller.camera.center;
    final endZoom = controller.camera.zoom;

    final distance = const Distance().as(
      LengthUnit.Meter,
      startCenter,
      endCenter,
    );

    // Zur Diagnose ausgeben, auch wenn der Test durchlaeuft.
    // ignore: avoid_print
    print(
      'Zoom $startZoom -> $endZoom | Zentrum $startCenter -> $endCenter '
      '(${distance.round()} m verschoben)',
    );

    expect(
      endZoom,
      greaterThan(startZoom),
      reason: 'die Geste soll hineinzoomen',
    );
    expect(
      distance,
      lessThan(2000),
      reason: 'die Kamera darf beim Zoomen nicht davonlaufen',
    );
  });

  testWidgets('zweiter Finger setzt spaeter auf', (tester) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = MapController();
    await tester.pumpWidget(
      _buildMap(controller, io: const InteractionOptions()),
    );
    await tester.pumpAndSettle();

    final startCenter = controller.camera.center;
    final startZoom = controller.camera.zoom;

    await _pinchOpenStaggered(tester);

    // ignore: avoid_print
    print(
      'versetzt: Zoom $startZoom -> ${controller.camera.zoom} | '
      '${_metres(startCenter, controller.camera.center).round()} m verschoben',
    );

    expect(
      _metres(startCenter, controller.camera.center),
      lessThan(2000),
      reason: 'die Kamera darf beim Zoomen nicht davonlaufen',
    );
  });

  testWidgets('Kneifgeste abseits der Bildmitte', (tester) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = MapController();
    await tester.pumpWidget(
      _buildMap(controller, io: const InteractionOptions()),
    );
    await tester.pumpAndSettle();

    final startCenter = controller.camera.center;

    await _pinchOpenStaggered(
      tester,
      offsetFromCentre: const Offset(-320, -180),
    );

    // ignore: avoid_print
    print(
      'abseits: Zoom -> ${controller.camera.zoom} | '
      '${_metres(startCenter, controller.camera.center).round()} m verschoben',
    );

    // Mit den Standardeinstellungen verankert flutter_map den Zoom am
    // Brennpunkt zwischen den Fingern - das Zentrum wandert dann weit.
    expect(
      _metres(startCenter, controller.camera.center),
      greaterThan(4000),
      reason: 'zeigt das Verhalten, das behoben werden soll',
    );
  });

  testWidgets('ohne Zwei-Finger-Verschieben bleibt die Karte stehen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = MapController();
    await tester.pumpWidget(
      _buildMap(
        controller,
        io: const InteractionOptions(
          flags:
              InteractiveFlag.drag |
              InteractiveFlag.flingAnimation |
              InteractiveFlag.pinchZoom |
              InteractiveFlag.doubleTapZoom |
              InteractiveFlag.doubleTapDragZoom |
              InteractiveFlag.scrollWheelZoom,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final startCenter = controller.camera.center;
    final startZoom = controller.camera.zoom;

    await _pinchOpenStaggered(
      tester,
      offsetFromCentre: const Offset(-320, -180),
    );

    // ignore: avoid_print
    print(
      'ohne pinchMove: Zoom $startZoom -> ${controller.camera.zoom} | '
      '${_metres(startCenter, controller.camera.center).round()} m verschoben '
      '| Drehung ${controller.camera.rotation}',
    );

    expect(controller.camera.zoom, greaterThan(startZoom));
    expect(
      _metres(startCenter, controller.camera.center),
      lessThan(500),
      reason: 'der Zoom soll die Bildmitte behalten',
    );
    expect(controller.camera.rotation, 0, reason: 'nichts darf sich drehen');
  });
}
