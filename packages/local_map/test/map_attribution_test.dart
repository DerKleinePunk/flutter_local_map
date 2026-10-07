import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';

/// Karte ohne Kacheln auf dem 1024x600 des Pi, darauf die Quellenangabe wie
/// in MapView.
Future<void> _pumpMap(WidgetTester tester, Widget attribution) async {
  tester.view.physicalSize = const Size(1024, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FlutterMap(
          options: const MapOptions(
            initialCenter: LatLng(50.31, 9.46),
            initialZoom: 11,
          ),
          children: [attribution],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('Quellenangabe steht ohne Antippen rechts unten', (tester) async {
    await _pumpMap(tester, const MapAttribution());

    final text = find.text('© OpenStreetMap contributors');
    expect(text, findsOneWidget);
    final box = tester.getRect(
      find.ancestor(of: text, matching: find.byType(DecoratedBox)).first,
    );
    // 4 px Abstand zum rechten und unteren Rand.
    expect(box.right, closeTo(1020, 0.5));
    expect(box.bottom, closeTo(596, 0.5));
    expect(box.left, greaterThan(512), reason: 'rechte Hälfte');
  });

  testWidgets('Text, Ecke und Abstand kommen aus der Config', (tester) async {
    // So legt CarNine den Hinweis zwischen Kompass und Fahrtpanel.
    final config = MapConfig(
      attributionText: MapConfig.osmAttributionGerman,
      attributionPadding: const EdgeInsets.only(right: 8, bottom: 125),
    );
    await _pumpMap(tester, MapAttribution.fromConfig(config));

    final text = find.text('© OpenStreetMap-Mitwirkende');
    expect(text, findsOneWidget);
    expect(find.text(MapConfig.osmAttribution), findsNothing);
    final box = tester.getRect(
      find.ancestor(of: text, matching: find.byType(DecoratedBox)).first,
    );
    expect(box.right, closeTo(1016, 0.5));
    expect(box.bottom, closeTo(475, 0.5));
  });

  testWidgets('andere Ecke: links oben', (tester) async {
    await _pumpMap(
      tester,
      MapAttribution.fromConfig(
        MapConfig(attributionAlignment: Alignment.topLeft),
      ),
    );
    final box = tester.getRect(
      find
          .ancestor(
            of: find.text(MapConfig.osmAttribution),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    expect(box.left, closeTo(4, 0.5));
    expect(box.top, closeTo(4, 0.5));
  });

  test('Defaults und copyWith', () {
    final config = MapConfig();
    expect(config.attributionText, '© OpenStreetMap contributors');
    expect(config.attributionAlignment, Alignment.bottomRight);
    expect(config.attributionPadding, const EdgeInsets.all(4));

    final changed = config.copyWith(
      attributionText: MapConfig.osmAttributionGerman,
      attributionAlignment: Alignment.topRight,
      attributionPadding: const EdgeInsets.only(bottom: 125),
    );
    expect(changed.attributionText, '© OpenStreetMap-Mitwirkende');
    expect(changed.attributionAlignment, Alignment.topRight);
    expect(changed.attributionPadding, const EdgeInsets.only(bottom: 125));

    // Unberührt bleibt, was nicht angegeben ist.
    final same = changed.copyWith(initialZoom: 12);
    expect(same.attributionText, changed.attributionText);
    expect(same.attributionAlignment, changed.attributionAlignment);
    expect(same.attributionPadding, changed.attributionPadding);
  });
}
