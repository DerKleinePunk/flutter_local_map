# local_map

Offline-Kartendarstellung als wiederverwendbares Flutter-Package: MBTiles
(Raster **und** Vektor/pbf), Offline-Geocoding über eine SQLite-Namensdatenbank,
Routing gegen einen lokalen Valhalla-Server und ein NMEA-GPS-Simulator.

Das Package ist aus der Desktop-App im Repository-Root (`map_local`)
herausgezogen. Diese App bleibt die Referenz-Implementierung und zeigt, wie das
Package eingebunden wird — siehe [`../../lib/main.dart`](../../lib/main.dart).

## Einbinden

### Variante A: lokale path-Dependency (zum Entwickeln/Testen)

```yaml
# pubspec.yaml des konsumierenden Projekts
dependencies:
  local_map:
    path: ../flutter_local_map/packages/local_map
```

### Variante B: git-Dependency (rechnerübergreifend)

```yaml
dependencies:
  local_map:
    git:
      url: https://github.com/DerKleinePunk/flutter_local_map
      ref: local_map-v0.4.0
      path: packages/local_map
```

Besser eine feste Marke `local_map-vX.Y.Z` als `master`: jede Version hat
einen Eintrag in [CHANGELOG.md](CHANGELOG.md), und ein Wechsel der Marke ist
dann eine bewusste Entscheidung des Gastgebers.

### Pflicht in beiden Varianten: dependency_overrides

`local_map` benötigt drei geforkte Abhängigkeiten. `dependency_overrides`
werden von pub **nur im Root-Package** ausgewertet und **nicht** transitiv
vererbt — ohne die folgenden Zeilen scheitert `flutter pub get` im
konsumierenden Projekt an Versionskonflikten:

```yaml
dependency_overrides:
  vector_map_tiles:
    git:
      url: https://github.com/DerKleinePunk/flutter-vector-map-tiles
      ref: local_map_pi
  flutter_map_mbtiles:
    git:
      url: https://github.com/DerKleinePunk/flutter_map_plugins
      ref: to_flutter_map_8
      path: flutter_map_mbtiles
  vector_map_tiles_mbtiles:
    git:
      url: https://github.com/DerKleinePunk/flutter_map_plugins
      ref: to_flutter_map_8
      path: vector_map_tiles_mbtiles
```

Die beiden aus `flutter_map_plugins` sind wegen `mbtiles` noetig: die
pub.dev-Versionen haengen an `^0.4.0`, dieses Package nutzt `^0.5.0`.

`vector_map_tiles` kommt aus einem Fork von 9.0.0-beta.13 (Branch
`local_map_pi`), der `panBuffer` und `rasterTileScale` einstellbar macht.
`MapView` uebergibt beides aus `MapConfig`; ohne den Fork kompiliert
`local_map` nicht. Beide Werte sind auf dem Pi gemessen, siehe
`MapConfig.panBuffer` und `MapConfig.rasterTileScale`.

## Verwenden

```dart
import 'package:flutter/material.dart';
import 'package:local_map/local_map.dart';

void main() {
  // Bindet sqflite-FFI auf Desktop ein und setzt die Default-Config.
  LocalMap.ensureInitialized(
    config: MapConfig(
      center: const LatLng(52.3759, 9.7320), // Hannover
      minZoom: 8,
      maxZoom: 16,
      initialZoom: 12,
      mbtilesFilename: 'niedersachsen.mbtiles',
      // cameraBounds weglassen => Karte ist nicht auf eine Region begrenzt
    ),
  );

  runApp(const MaterialApp(home: Scaffold(body: MyMapPage())));
}

class MyMapPage extends StatelessWidget {
  const MyMapPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const MapView(mbtilesPath: '/pfad/zu/karte.mbtiles');
  }
}
```

`MapConfig` kann alternativ pro Widget übergeben werden, dann ist
`LocalMap.ensureInitialized()` ohne `config:` ausreichend:

```dart
MapView(mbtilesPath: path, config: myConfig)
```

Ohne `config:` greifen Widgets und Services auf `MapConfig.defaults` zurück.

## Steuern: LocalMapController

`MapView` zeichnet nur die Karte: Kacheln und darüber Route, Start und Ziel,
einen hervorgehobenen Ort und die eigene Position. **Bedienelemente bringt sie
nicht mit** — Suchfelder, Zoomknöpfe und Anzeigen baut die App selbst und legt
sie über die Karte. Gesteuert wird über einen `LocalMapController`:

```dart
final map = LocalMapController(
  routingProvider: ValhallaRoutingService(),   // oder eigene Implementierung
  positionSource: meinePositionsquelle,        // z. B. GpsNmeaSimulatorService
);

// im build():
Stack(children: [
  MapView(mbtilesPath: path, controller: map),
  // eigene Knöpfe darüber, z. B.
  Positioned(bottom: 16, right: 16,
      child: IconButton(icon: const Icon(Icons.add), onPressed: map.zoomIn)),
]);

// Befehle
await map.setStart(ort);          // Route wird neu berechnet,
await map.setDestination(ziel);   // sobald Start und Ziel da sind
map.showPlace(treffer);           // hervorheben und hinspringen
map.followPosition = true;        // Kamera folgt der Position
```

Der Controller ist ein `ChangeNotifier` (Route, `isRouting`, `routingError`,
`position`, `isVectorMode`, `activeStyleName` …); der Zoom kommt getrennt als
`map.zoom` (`ValueListenable<double>`). Wer die Farben der Ebenen anpassen
will, übergibt `MapView(layerStyle: MapLayerStyle(routeColor: …))`.

Eine vollständige Bedienung mit Suche, Routing-Anzeige und GPS-Simulator
zeigt `lib/map_screen.dart` der Demo-App im Repository-Root.

### Eigene Quellen

Routing, Position und Suche sind Schnittstellen. Ein Gastgeber, der sie
selbst liefert (etwa aus einem eigenen Backend), implementiert:

| Schnittstelle | Mitgelieferte Implementierung | Aufgabe |
| --- | --- | --- |
| `RoutingProvider` | `ValhallaRoutingService` (HTTP) | `route(start: …, end: …)` → `RoutingResult` mit Geometrie und Manövern; ohne `start` ab der eigenen Position. `isAvailable()` für die Anzeige |
| `PositionSource` | `GpsNmeaSimulatorService` (NMEA-Aufzeichnung) | `Stream<PositionFix>` mit Position, Kurs, Geschwindigkeit |
| `PlaceSearch` | `OfflineGeocoder` (SQLite/FTS5) | `searchPlaces(query, near: …)` für `PlaceSearchBar`; mit `near` zuerst Treffer in der Nähe |

Eine fertig berechnete Route – etwa vom eigenen Backend oder per
Map-Matching aus einer Aufzeichnung (`ValhallaRoutingService.routeAlongTrace`)
– übernimmt `map.setRoute(route)`, ohne den `RoutingProvider` zu fragen.

Meldungen der Karte lassen sich mit `MapErrorHandler.sink = …` in das eigene
Logging umleiten.

Kann die Karte nichts zeigen (keine oder unlesbare MBTiles, unpassender Stil),
erscheint an ihrer Stelle `MapError.userMessage` — englisch. Übersetzt wird
über `errorBuilder` anhand der Kategorie:

```dart
MapView(
  mbtilesPath: path,
  errorBuilder: (context, error) => Center(
    child: Text(switch (error.category) {
      MapErrorCategory.noMapData => 'Keine Kartendaten vorhanden',
      _ => 'Karte kann nicht angezeigt werden',
    }),
  ),
)
```

### Navigationsmodus

```dart
map.followPosition = true;  // Kamera folgt der Position
map.headingUp = true;       // Karte dreht nach Kurs; false = Norden oben
```

Der Kurs kommt aus `PositionFix`, geglättet und im Stand eingefroren
(`HeadingFilter`). Mit Route und Position liefert `map.progress` ein
`RouteProgress`: Reststrecke, Restzeit, nächstes Manöver und der Abstand
dorthin. **Anzeigen tut das der Gastgeber** – Abbiegekarte und Fahrtleiste
gehören in die App, nicht in die Karte.

### Texte

`PlaceSearchBar`, `DownloadOverlay` und `StorageSettingsDialog` nehmen ihre
Texte aus `PlaceSearchTexts`, `DownloadOverlayTexts` und
`StorageSettingsTexts`. Die Vorgabe ist englisch, `.german` liefert die
deutschen Texte; für weitere Sprachen eigene Instanzen übergeben.

## MapConfig

| Feld | Default | Bedeutung |
| --- | --- | --- |
| `center` | `null` | Kartenmittelpunkt beim Start; `null` = Mitte der Kacheln laut MBTiles-Metadaten |
| `cameraBounds` | `null` | Kamera-Begrenzung; `null` = unbegrenzt |
| `minZoom` / `maxZoom` / `initialZoom` | `10` / `14` / `11` | Zoom-Grenzen. MBTiles-Metadaten haben für min/max Vorrang |
| `mbtilesFilename` | `germany.mbtiles` | Dateiname, den `MapDownloader` erwartet |
| `downloadUrl` | Platzhalter | Quelle für `MapDownloader.downloadMap()` |
| `estimatedFileSizeMB` | `250` | Anzeige im `DownloadOverlay` |
| `storageLocation` / `storageSubdirectory` / `customStoragePath` | `applicationSupport` / `offline_maps` / `null` | Ablageort der MBTiles |
| `vectorStyleAssets` | 3 Package-Styles | Vektorstyles, der Reihe nach probiert |
| `initialVectorStyleIndex` | `2` | Welcher Style zuerst geladen wird |
| `valhallaBaseUri` | `http://127.0.0.1:8002` | Endpunkt des lokalen Routers |
| `gpsTourFilePaths` | leer | NMEA-Tourdatei für den GPS-Simulator |
| `rasterUrlTemplate` | `mbtiles://local` | Pflichtfeld des Raster-`TileLayer` |
| `searchResultZoom` | `15` | Zoom beim Anspringen eines Suchtreffers; `null` = Zoom des Geocoder-Treffers |
| `panBuffer` | `0` | Kachelreihen außerhalb des Bildes (Vektor im Raster-Modus); `0` halbiert auf dem Pi die Ladezeit |
| `rasterTileScale` | `null` | Auflösungsfaktor beim Rastern der Vektorkacheln; `null` = Pixelverhältnis des Bildschirms statt fest 2,0 |
| `memoryTileCacheMaxSize` / `memoryTileDataCacheMaxSize` / `textCacheMaxSize` / `vectorConcurrency` / `vectorLayerMode` | `null` | Speicher- und Thread-Budget von `vector_map_tiles`; `null` = dessen Vorgabe |

`MapConfig.defaults` ist ein `MapConfig()` ohne Ortsbezug. `MapConfig.hessen`
liefert das Setup der Demo-App: Start bei Alsfeld, Kamera-Begrenzung auf
Hessen und die mitgelieferte GPS-Tour.

## Eigene Vektorstyles

`vectorStyleAssets` erwartet vollständig qualifizierte Asset-Pfade. Styles aus
dem eigenen Projekt werden direkt angegeben, Styles aus einem Package mit dem
`packages/<name>/`-Präfix:

```dart
MapConfig(
  vectorStyleAssets: const [
    'assets/my_style.json',                          // eigenes Projekt
    ...MapConfig.packageVectorStyleAssets,           // Styles dieses Packages
  ],
)
```

Die mitgelieferten Styles liegen unter
`packages/local_map/assets/maps/` und werden automatisch mitgebundelt.

## Geocoding

`OfflineGeocoder` sucht in einer Namensdatenbank, die mit
`scripts/extract_names_to_sqlite.py` im Repository-Root erzeugt wird. Die
Demo-App legt sie neben die MBTiles-Datei (aus `karte.mbtiles` wird
`karte_names.db`); `MapView` selbst braucht sie nicht.

## Öffentliche API

`package:local_map/local_map.dart` exportiert:

- **Setup:** `LocalMap`, `MapConfig`, `MapStorageLocation`
- **Steuerung:** `LocalMapController`, `MapLayerStyle`
- **Navigation:** `RouteTracker`, `RouteProgress`, `HeadingFilter`
- **Schnittstellen:** `RoutingProvider`, `PositionSource`, `PlaceSearch`
- **Widgets:** `MapView`, `DownloadOverlay`, `PlaceSearchBar`,
  `StorageSettingsDialog`, dazu ihre Texte `DownloadOverlayTexts`,
  `PlaceSearchTexts`, `StorageSettingsTexts` und `DownloadStatus`
- **Services:** `MapDownloader`, `StoragePreferences`, `OfflineGeocoder`,
  `ValhallaRoutingService`, `GpsNmeaSimulatorService`, `MapErrorHandler`
- **Modelle:** `GeocoderResult`, `RoutingResult`, `RoutingManeuver`,
  `RoutingPoint`, `PositionFix`, `SimulatedGpsFix`, `MapError`,
  `MapErrorCategory`, `MapLogLevel`, `MbTilesException`, `RoutingException`
- **Durchgereicht:** `LatLng`, `LatLngBounds`, `MapController`

## Einsatz auf eingebettetem Linux (emb_cli / ivi-homescreen)

Wer das Package auf einem schlanken Linux-Image betreibt — Raspberry Pi mit
`emb_cli`-Cross-Build unter ivi-homescreen, Yocto, Buildroot —, muss zwei
Dinge auf dem Zielgerät bereitstellen, die eine Desktop-Distribution
mitbringt und die das Flutter-Bundle **nicht** enthält:

1. **Eine Schriftart.** Ohne installierte Schrift zeichnet Skia keinen
   einzigen Buchstaben. Die Karte erscheint dann mit Geometrie, aber ohne
   jede Beschriftung — ohne Fehlermeldung und ohne Logzeile. RaspiOS Lite hat
   kein `/usr/share/fonts`; `sudo apt install fonts-dejavu-core` genügt für
   deutsche Karten. Prüfen mit
   `find /usr/share/fonts -type f -name '*.ttf' | wc -l`. Für ein Kiosk-Image
   ist es robuster, eine Schrift als Flutter-Asset ins Bundle zu legen, statt
   sich auf das System zu verlassen.
2. **Ein XCursor-Theme**, falls mit Maus oder Touchpad bedient wird
   (`sudo apt install adwaita-icon-theme`, Start mit `-t Adwaita`). Sonst ist
   der Mauszeiger unsichtbar, was wie tote Eingabe aussieht.

**Gestenbedienung:** Ein Finger verschiebt, zwei Finger zoomen. Zwei Finger
verschieben und drehen bewusst **nicht**: `flutter_map` verankert den Zoom sonst
am Brennpunkt zwischen den Fingern, was auf einem kleinen Kartenausschnitt die
Kacheln aus dem Bild schiebt (bei Zoom 11 verschiebt ein Griff 320 px neben der
Bildmitte das Zentrum um über 10 km). Gemessen in
[test/pinch_gesture_test.dart](test/pinch_gesture_test.dart).

**Zoomknöpfe** bringt `MapView` nicht mit. `map.zoomIn()` und `map.zoomOut()`
schalten eine ganze Zoomstufe weiter und behalten die Bildmitte; die Knöpfe
dazu legt der Gastgeber über die Karte (Beispiel: `lib/map_screen.dart` der
Demo-App, 56 px, am Anschlag abgeschaltet). Auf einem kleinen
Fahrzeugdisplay ist das die verlässliche Bedienung — die Kneifgeste braucht
zwei Finger und eine ruhige Hand.

**Tastaturbedienung:** Pfeiltasten schieben die Karte, **R** zoomt hinein, **F**
heraus. Auf einem Ziel ohne angeschlossenes Zeigergerät — etwa bei der
Inbetriebnahme, solange der Touchscreen fehlt — ist das die einzige
Möglichkeit, die Karte zu bewegen.

Eine Startposition aus [`MapConfig.center`](lib/src/config/map_config.dart) muss
in den `bounds` der verwendeten MBTiles liegen. Tut sie das nicht, rückt das
Package die Kamera in die Mitte der vorhandenen Kacheln und protokolliert das
mit `[MapError] ERROR [Camera bounds]: ...` — diese Zeile erscheint auch im
Release-Build.

## Tests

```bash
cd packages/local_map
flutter test
```

Die Tests, die echte MBTiles-Dateien unter `map/` brauchen, liegen weiterhin im
Repository-Root (`../../test/`), weil sie relativ zum Repo-Wurzelverzeichnis
auflösen.
