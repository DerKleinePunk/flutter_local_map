# Changelog

## Unveröffentlicht

- Neue Schnittstelle `ReverseGeocoder` mit `LocationName` (Straße, Ort,
  Ortsteil). `OfflineGeocoder` implementiert sie über die neuen
  `reverse_*`-Tabellen der Namensdatenbank.
- `LocalMapController` nimmt optional einen `reverseGeocoder` und führt ohne
  Route `locationName` nach, sobald man sich 25 m bewegt hat.
- `GeocoderResult.area`: der Ort, zu dem ein Treffer gehört (bei Orten der
  größere Ort in der Nähe). Die Namensdatenbank kennt Namen jetzt einmal je
  Ort statt einmal im ganzen Land, gleichnamige Straßen und Bahnhöfe
  unterscheidet erst `area`.
- `searchPlaces` mit `near` sucht zuerst im Umkreis von 50 km (ab drei
  Zeichen), dann landesweit. Genaue Treffer stehen vor Teiltreffern, POIs,
  die wie eine Straße im selben Ort heißen, hinter den Straßen. „Hauptstraße
  Alsfeld“ findet Name und Ort zusammen. Bindestriche in der Eingabe führen
  nicht mehr zu einem FTS-Syntaxfehler.
- `PlaceSearchBar` sucht nahe `nearPosition` (Vorgabe: Kartenmitte), behält
  die Reihenfolge der Suche bei und zeigt „Typ · Ort · Entfernung“ statt
  Klasse und Zoom. Neue Texte `PlaceSearchTexts.near` und `decimalSeparator`.
- `GeocoderResult.searchRank` ersetzt die feste Typ-Rangfolge,
  `typePriority` gibt ihn weiter. Benannte Stellen ohne Einwohner
  (`locality`, Plätze, Felder) zählen wie Straßen.
- Suche auf dem Pi 4 mit DACH (5,3 Mio. Namen) unter 180 ms statt bis zu
  3,4 s: Typ und Rasterfeld stehen im Suchindex, kurze Eingaben nutzen den
  Präfix-Index. Das braucht eine Namensdatenbank mit der Spalte `cell`;
  ältere suchen weiter landesweit.

## 0.4.1

- Die mitgelieferten Vektorstyles beschriften jetzt: Sie lesen die Namen
  aus `name:latin` (Rückfall `name`). tilemaker schreibt Namen nur als
  `name:latin`, mit `{name}` erschien kein Orts-, Straßen- oder
  Gewässername.
- `id` und `metadata.version` der drei Styles sind erhöht, damit
  `vector_map_tiles` keine gecachten Kacheln vom alten Stand zeigt.

## 0.4.0

- `PlaceSearchBar`, `DownloadOverlay` und `StorageSettingsDialog` nehmen ihre
  Texte aus `PlaceSearchTexts`, `DownloadOverlayTexts` und
  `StorageSettingsTexts`. Die Vorgabe ist jetzt englisch (vorher deutsch); die
  bisherigen Texte liefern die Konstanten `.german`.
- `hintText` von `PlaceSearchBar` und `title` von `DownloadOverlay` sind
  optional und überschreiben den Wert aus den Texten.
- `GeocoderResult.typeLabel` und `MapDownloader.storageLocationName` sind
  englisch.

## 0.3.0

- `MapView.errorBuilder`: Fehler an Stelle der Karte selbst darstellen und
  anhand von `MapError.category` übersetzen. Neue Kategorie `noMapData`.
- `MapError.userMessage` ist jetzt englisch (vorher deutsch).
- `MapConfig.center` ist optional; ohne Angabe startet die Karte in der Mitte
  der Kacheln. `MapConfig.defaults` ist ortsneutral, `gpsTourFilePaths` ist
  standardmäßig leer. Das bisherige Verhalten liefert `MapConfig.hessen`.

## 0.2.0

Die Karte bezieht Routing, Position und Suche jetzt über Schnittstellen und
bringt keine eigene Bedienung mehr mit. Das bricht die API von 0.1.0.

- `RoutingProvider`, `PositionSource`, `PlaceSearch`: Der Gastgeber entscheidet,
  woher Route, Position und Suchtreffer kommen. `ValhallaRoutingService`,
  `GpsNmeaSimulatorService` und `OfflineGeocoder` sind mitgelieferte
  Umsetzungen. Log-Ausgaben gehen über `MapErrorHandler.sink`.
- `LocalMapController` hält Zustand und Befehle (Start/Ziel, Route, Zoom,
  Stil, Folgen). `MapView` zeichnet nur noch Kacheln und Ebenen; Suchfelder
  und Knöpfe legt der Gastgeber darüber.
- Navigationsmodus: `headingUp` dreht die Karte nach Kurs, `RouteTracker`
  liefert `RouteProgress` (Reststrecke, Restzeit, nächstes Manöver).
- `ValhallaRoutingService.routeAlongTrace`: aufgezeichnete Tour per
  Map-Matching als Route, auch wenn sie dieselbe Straße zurückfährt;
  `language` für die Anweisungen.
- Ortssuche mit `near`; der genaue Name steht vor Präfix-Treffern.
- `MapLayerStyle` für die Farben der Ebenen, mit `backgroundColor` gegen
  einen hellen Blitz vor dem ersten Kachelbild.

## 0.1.0

Erste Fassung, aus der Demo-App herausgelöst.
