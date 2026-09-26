import 'package:latlong2/latlong.dart';

/// Wo eine Position liegt, in Worten: Straße, Ort und Ortsteil.
///
/// Jedes Feld kann fehlen - auf freiem Feld gibt es keine Straße, und nicht
/// jeder Ort hat Ortsteile.
class LocationName {
  /// Die nächste Straße, bei Autobahnen oft nur die Nummer ("A 5").
  final String? street;

  /// Der Ort: Stadt, Gemeinde oder Dorf.
  final String? locality;

  /// Ortsteil oder Stadtviertel, wenn einer nahe liegt und anders heißt als
  /// [locality].
  final String? district;

  const LocationName({this.street, this.locality, this.district});

  bool get isEmpty => street == null && locality == null && district == null;

  /// "Straße, Ort (Ortsteil)" mit dem, was davon bekannt ist.
  String get label {
    final place = [?locality, if (district != null) '($district)'].join(' ');
    return [?street, if (place.isNotEmpty) place].join(', ');
  }

  @override
  bool operator ==(Object other) =>
      other is LocationName &&
      other.street == street &&
      other.locality == locality &&
      other.district == district;

  @override
  int get hashCode => Object.hash(street, locality, district);

  @override
  String toString() => label;
}

/// Sagt zu einer Position, wo sie liegt - für die Anzeige "wo bin ich"
/// außerhalb einer Zielführung.
///
/// [OfflineGeocoder] liest dafür die Namensdatenbank. Ein Fahrzeugsystem
/// kann die Frage ebenso an sein Backend stellen.
abstract interface class ReverseGeocoder {
  /// Straße, Ort und Ortsteil an [position], `null` wenn nichts bekannt ist
  /// (keine Daten für die Gegend, oder die Quelle kann das nicht).
  Future<LocationName?> nameAt(LatLng position);
}
