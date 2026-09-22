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
      ref: master
      path: packages/local_map
```

### Pflicht in beiden Varianten: dependency_overrides

`local_map` benötigt zwei geforkte Abhängigkeiten. `dependency_overrides`
werden von pub **nur im Root-Package** ausgewertet und **nicht** transitiv
vererbt — ohne die folgenden Zeilen scheitert `flutter pub get` im
konsumierenden Projekt an Versionskonflikten:

```yaml
dependency_overrides:
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

Noetig sind die beiden wegen `mbtiles`: die pub.dev-Versionen haengen an
`^0.4.0`, dieses Package nutzt `^0.5.0`. `vector_map_tiles` selbst kommt seit
9.0.0-beta.13 direkt von pub.dev und braucht **kein** Override mehr.

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

## MapConfig

| Feld | Default | Bedeutung |
| --- | --- | --- |
| `center` | `50.6521, 9.1624` | Kartenmittelpunkt beim Start |
| `cameraBounds` | `null` | Kamera-Begrenzung; `null` = unbegrenzt |
| `minZoom` / `maxZoom` / `initialZoom` | `10` / `14` / `11` | Zoom-Grenzen. MBTiles-Metadaten haben für min/max Vorrang |
| `mbtilesFilename` | `germany.mbtiles` | Dateiname, den `MapDownloader` erwartet |
| `downloadUrl` | Platzhalter | Quelle für `MapDownloader.downloadMap()` |
| `estimatedFileSizeMB` | `250` | Anzeige im `DownloadOverlay` |
| `storageLocation` / `storageSubdirectory` / `customStoragePath` | `applicationSupport` / `offline_maps` / `null` | Ablageort der MBTiles |
| `vectorStyleAssets` | 3 Package-Styles | Vektorstyles, der Reihe nach probiert |
| `initialVectorStyleIndex` | `2` | Welcher Style zuerst geladen wird |
| `valhallaBaseUri` | `http://127.0.0.1:8002` | Endpunkt des lokalen Routers |
| `gpsTourFilePaths` | `scripts/gpstest/…` | NMEA-Tourdatei für den GPS-Simulator |
| `rasterUrlTemplate` | `mbtiles://local` | Pflichtfeld des Raster-`TileLayer` |

`MapConfig.hessen` liefert das ursprüngliche Setup dieses Repos inklusive
Kamera-Begrenzung auf Hessen.

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

`MapView` sucht die Namensdatenbank neben der MBTiles-Datei: aus
`karte.mbtiles` wird `karte_names.db`. Fehlt sie, bleibt die Suchleiste ohne
Ergebnisse — die Karte funktioniert trotzdem. Die Datenbank wird mit
`scripts/extract_names_to_sqlite.py` im Repository-Root erzeugt.

## Öffentliche API

`package:local_map/local_map.dart` exportiert:

- **Setup:** `LocalMap`, `MapConfig`, `MapStorageLocation`
- **Widgets:** `MapView`, `DownloadOverlay`, `PlaceSearchBar`,
  `StorageSettingsDialog`
- **Services:** `MapDownloader`, `StoragePreferences`, `OfflineGeocoder`,
  `ValhallaRoutingService`, `GpsNmeaSimulatorService`, `MapErrorHandler`
- **Modelle:** `GeocoderResult`, `RoutingResult`, `RoutingManeuver`,
  `RoutingPoint`, `SimulatedGpsFix`, `MapError`, `MapErrorCategory`,
  `MbTilesException`, `RoutingException`
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

**Tastaturbedienung:** Pfeiltasten schieben die Karte, **R** zoomt hinein, **F**
heraus. Auf einem Ziel ohne angeschlossenes Zeigergerät — etwa bei der
Inbetriebnahme, solange der Touchscreen fehlt — ist das die einzige
Möglichkeit, die Karte zu bewegen.

Die Startposition aus [`MapConfig.center`](lib/src/config/map_config.dart) muss
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
