import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:map_local/services/offline_geocoder.dart';
import 'package:map_local/widgets/search_bar.dart';

void main() {
  testWidgets('Suggestion tap calls select callback after delayed release', (
    WidgetTester tester,
  ) async {
    final pointerDownNames = <String>[];
    final selectedNames = <String>[];
    final mapController = MapController();

    Future<List<GeocoderResult>> fakeSearch(String query, int limit) async {
      return [
        GeocoderResult(
          name: 'Alsfeld',
          location: const LatLng(50.7519, 9.2692),
          zoom: 14,
          type: 'place',
        ),
      ];
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaceSearchBar(
            mapController: mapController,
            geocoder: OfflineGeocoder(),
            searchDelegate: fakeSearch,
            moveToResult: (controller, result) {},
            onSuggestionPointerDown: (result) {
              pointerDownNames.add(result.name);
            },
            onPlaceSelected: (result) {
              selectedNames.add(result.name);
            },
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'als');
    await tester.pump();
    await tester.pump();

    final suggestion = find.text('Alsfeld');
    expect(suggestion, findsOneWidget);

    final center = tester.getCenter(suggestion);
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(pointerDownNames, contains('Alsfeld'));
    expect(selectedNames, contains('Alsfeld'));

    // Dispose widget tree after timers have settled.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Suggestion list hides after unfocus without selection', (
    WidgetTester tester,
  ) async {
    final mapController = MapController();

    Future<List<GeocoderResult>> fakeSearch(String query, int limit) async {
      return [
        GeocoderResult(
          name: 'Fulda',
          location: const LatLng(50.5558, 9.6808),
          zoom: 13,
          type: 'place',
        ),
      ];
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaceSearchBar(
            mapController: mapController,
            geocoder: OfflineGeocoder(),
            searchDelegate: fakeSearch,
            moveToResult: (controller, result) {},
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'ful');
    await tester.pump();
    await tester.pump();
    expect(find.text('Fulda'), findsOneWidget);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 180));

    expect(find.text('Fulda'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Selecting suggestion forwards expected map target data', (
    WidgetTester tester,
  ) async {
    final mapController = MapController();
    GeocoderResult? movedResult;

    Future<List<GeocoderResult>> fakeSearch(String query, int limit) async {
      return [
        GeocoderResult(
          name: 'Marburg',
          location: const LatLng(50.8075, 8.7708),
          zoom: 12,
          type: 'place',
        ),
      ];
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaceSearchBar(
            mapController: mapController,
            geocoder: OfflineGeocoder(),
            searchDelegate: fakeSearch,
            moveToResult: (controller, result) {
              movedResult = result;
            },
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'mar');
    await tester.pump();
    await tester.pump();

    expect(find.text('Marburg'), findsOneWidget);
    await tester.tap(find.text('Marburg'));
    await tester.pump();

    expect(movedResult, isNotNull);
    expect(movedResult!.name, 'Marburg');
    expect(movedResult!.zoom, 12);
    expect(movedResult!.location.latitude, closeTo(50.8075, 0.000001));
    expect(movedResult!.location.longitude, closeTo(8.7708, 0.000001));

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('Empty query shows no suggestions and skips search call', (
    WidgetTester tester,
  ) async {
    final mapController = MapController();
    var searchCallCount = 0;

    Future<List<GeocoderResult>> fakeSearch(String query, int limit) async {
      searchCallCount++;
      return [
        GeocoderResult(
          name: 'Giesen',
          location: const LatLng(52.1979, 9.8986),
          zoom: 11,
          type: 'place',
        ),
      ];
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaceSearchBar(
            mapController: mapController,
            geocoder: OfflineGeocoder(),
            searchDelegate: fakeSearch,
            moveToResult: (controller, result) {},
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'gie');
    await tester.pump();
    await tester.pump();
    expect(searchCallCount, 1);
    expect(find.text('Giesen'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();

    expect(searchCallCount, 1);
    expect(find.text('Giesen'), findsNothing);
    expect(find.byType(ListTile), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
