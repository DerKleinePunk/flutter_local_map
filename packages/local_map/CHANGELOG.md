# Changelog

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
