import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_map/local_map.dart';

Future<List<GeocoderResult>> _fakeSearch(String query, int limit) async => [
  GeocoderResult(
    name: 'Wasserkuppe',
    location: const LatLng(50.4981, 9.9383),
    zoom: 14,
    type: 'mountain_peak',
  ),
];

Future<void> _pumpSearchBar(
  WidgetTester tester, {
  PlaceSearchTexts texts = const PlaceSearchTexts(),
  String? hintText,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PlaceSearchBar(
          mapController: MapController(),
          geocoder: OfflineGeocoder(),
          searchDelegate: _fakeSearch,
          texts: texts,
          hintText: hintText,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('PlaceSearchBar ist ohne Angabe englisch', (tester) async {
    await _pumpSearchBar(tester);
    expect(find.text('Search place...'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'wass');
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Peak'), findsOneWidget);
  });

  testWidgets('PlaceSearchBar zeigt die deutschen Texte', (tester) async {
    await _pumpSearchBar(tester, texts: PlaceSearchTexts.german);
    expect(find.text('Ort suchen...'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'wass');
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Berg'), findsOneWidget);
  });

  testWidgets('hintText geht vor den Texten', (tester) async {
    await _pumpSearchBar(
      tester,
      texts: PlaceSearchTexts.german,
      hintText: 'Ziel suchen...',
    );
    expect(find.text('Ziel suchen...'), findsOneWidget);
    expect(find.text('Ort suchen...'), findsNothing);
  });

  testWidgets('StorageSettingsDialog zeigt die gewaehlten Texte', (
    tester,
  ) async {
    Future<void> pump(StorageSettingsTexts texts) => tester.pumpWidget(
      MaterialApp(
        home: StorageSettingsDialog(
          currentLocation: MapStorageLocation.applicationSupport,
          texts: texts,
        ),
      ),
    );

    await pump(const StorageSettingsTexts());
    expect(find.text('Choose storage location'), findsOneWidget);
    expect(find.text('Application Support (default)'), findsOneWidget);

    await pump(StorageSettingsTexts.german);
    expect(find.text('Speicherort wählen'), findsOneWidget);
    expect(find.text('Speichern'), findsOneWidget);
  });

  test('DownloadOverlayTexts setzt Groesse und Speicherort ein', () {
    const en = DownloadOverlayTexts();
    expect(en.downloadRequired(250), 'Download required (~250 MB)');
    expect(en.locationName(MapStorageLocation.custom), 'Custom');

    const de = DownloadOverlayTexts.german;
    expect(de.downloadRequired(250), 'Download erforderlich (~250 MB)');
    expect(
      de.locationName(MapStorageLocation.applicationDocuments),
      'Dokumente',
    );
  });
}
