# Changelog

## 0.5.3

- `MapConfig.prefetchAheadSeconds`: Vorab-Laden in Fahrtrichtung (nur
  Raster-Modus), `0` = aus (Default). Nur bei einem GPS-Fix mit Kurs und
  über 3 m/s; Kacheln der nächsten Sekunden geradeaus, je Fix höchstens 12,
  die sichtbaren ausgenommen. Sie laufen nachrangig durch das Frame-Budget
  und nehmen sichtbaren Kacheln nichts weg. Wirkt erst ab etwa Zoom 14,
  darunter liegt der Korridor im Sichtbaren.
- Auf einem Pi 4 gemessen (Zoom 16, drei Paare): kein Frame mehr über
  100 ms (vorher 1–2 je 2 min), schlechtester Frame 101–124 → 84–88 ms,
  etwa 7 % mehr Frames über 33 ms. Speicher etwa +50 MB: die Bilder bleiben
  im Flutter-ImageCache, dessen Deckel (Standard 100 MB) die Obergrenze ist.
- Braucht vector_map_tiles aus dem Fork `local_map_pi` ab 8d730e2
  (`VectorTileController.prefetch`).

## 0.5.2

- `MapConfig.rasterTilesPerFrame`: wie viele neue Kacheln der Raster-Modus
  pro Frame rastert, `0` = unbegrenzt (Default, wie bisher). Kommen beim
  Schieben oder Zoomen viele Kacheln auf einmal, rastert die Engine sonst
  alle vor dem nächsten Frame. Auf carnine-pc (Pi 4) halbiert `2` im Mittel
  die Zeit in langen Frames, die Karte füllt sich dafür etwas später.
- Braucht vector_map_tiles aus dem Fork `local_map_pi` ab a7ccd5f. Seit 4de0ba4
  schreibt der Fork Kacheln aus MBTiles nicht mehr in den Dateicache
  `/tmp/.vector_map` (dazu vector_map_tiles_mbtiles ab 3342bab); auf carnine-pc
  sank dadurch die Rechenzeit der Oberfläche beim Schieben um etwa 30 %.

## 0.5.1

- `searchPlaces` mit `near`: Treffer aus dem Umkreis von 50 km stehen vor
  denen von weiter weg, erst darin gilt die Typ-Rangfolge. Bisher schlug der
  Bahnhof „Hauptstraße“ in Freiburg die Hauptstraßen um Alsfeld, weil POIs
  vor Straßen kamen. Bewohnte Orte bleiben vorn: „Berlin“ findet die Stadt,
  nicht das Gasthaus nebenan.

## 0.5.0

Braucht für Standortanzeige, Ortsbezug und Umkreissuche eine Namensdatenbank
aus `scripts/extract_names_to_sqlite.py` ab diesem Stand. Mit einer älteren
läuft alles wie in 0.4.1.

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
- `GeocoderResult.isRegion` für Gebiete (Bundesland, Kanton, Kreis …);
  `PlaceSearchBar` nennt sie „Gebiet“ statt „Ort“ (`PlaceSearchTexts.region`).
  Gebiete tragen keinen Ortsbezug mehr.
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
