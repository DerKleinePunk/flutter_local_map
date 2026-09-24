import '../services/offline_geocoder.dart';

/// Sucht Orte nach Namen, für Suchfelder über der Karte.
///
/// [OfflineGeocoder] sucht in einer lokalen Namensdatenbank. Ein
/// Fahrzeugsystem kann die Suche ebenso in sein Backend verlegen.
abstract interface class PlaceSearch {
  /// Treffer für [query], die wichtigsten zuerst (Orte vor POIs vor Bergen
  /// usw.), höchstens [limit] Stück.
  Future<List<GeocoderResult>> searchPlaces(String query, {int limit = 15});
}
