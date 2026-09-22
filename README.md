# map_local

Flutter-Desktop-App fuer Offline-Karten auf Basis von MBTiles mit Fokus auf Hessen.

## Ueberblick

Die App unterstuetzt zwei MBTiles-Typen:

- Raster-MBTiles (`png`, `jpg`, `jpeg`, `webp`) ueber `flutter_map_mbtiles`
- Vektor-MBTiles (`pbf`) ueber `vector_map_tiles_mbtiles` und `vector_map_tiles`

Die Entscheidung erfolgt zur Laufzeit anhand der MBTiles-Metadaten (`format`, `minzoom`, `maxzoom`).

## Features

- Offline-Kartenanzeige auf Windows und Linux
- Hybrid-Rendering fuer Raster und Vektor-MBTiles
- Dynamische Zoom-Grenzen aus MBTiles-Metadaten
- Geografische Begrenzung auf Hessen
- Zoom-Badge und Modus-Badge (Raster/Vektor)
- Download-Workflow fuer Kartendaten

## Voraussetzungen

- Flutter SDK (Dart SDK gemaess [pubspec.yaml](pubspec.yaml))
- Aktivierter Desktop-Support in Flutter
- Fuer lokale Tile-Erzeugung: Docker (optional zusaetzlich Python-Skripte)
- Fuer den Raster-Schritt: `git-lfs` (wird fuer `scripts/styles.zip` benoetigt – `sudo apt install git-lfs && git lfs install`)
- Fuer den experimentellen MapLibre-Renderer: Node.js + npm (getestet mit Node 24.x)
- Fuer `scripts/render_raster_test.py`: Python-Pakete `requests` und `tqdm` (Ubuntu: `sudo apt install python3-requests python3-tqdm`)
- Fuer `maplibre_native` unter Ubuntu: OpenGL/UV-Runtime (`sudo apt install libopengl0 libuv1`)

## Quick Start

1. Repository klonen und Abhaengigkeiten laden.

```bash
git clone <repository-url>
cd map_local
flutter pub get
```

2. App starten.

```bash
flutter run -d windows
# oder
flutter run -d linux
```

## Wichtige Dateien

- App-Konfiguration: [packages/local_map/lib/src/config/map_config.dart](packages/local_map/lib/src/config/map_config.dart)
- Karten-Widget: [packages/local_map/lib/src/widgets/map_view.dart](packages/local_map/lib/src/widgets/map_view.dart)
- Download-Service: [packages/local_map/lib/src/services/map_downloader.dart](packages/local_map/lib/src/services/map_downloader.dart)
- Routing-Service (Valhalla HTTP): [packages/local_map/lib/src/services/valhalla_routing_service.dart](packages/local_map/lib/src/services/valhalla_routing_service.dart)
- Valhalla Build-Skript (optional mit BBox): [scripts/valhalla/build_valhalla_from_pbf.sh](scripts/valhalla/build_valhalla_from_pbf.sh)
- Valhalla Run-Skript (lokaler Server): [scripts/valhalla/run_valhalla_server.sh](scripts/valhalla/run_valhalla_server.sh)
- Valhalla Build-Skript fuer Windows/Pwsh: [scripts/valhalla/build_valhalla_from_pbf.ps1](scripts/valhalla/build_valhalla_from_pbf.ps1)
- Valhalla Run-Skript fuer Windows/Pwsh: [scripts/valhalla/run_valhalla_server.ps1](scripts/valhalla/run_valhalla_server.ps1)
- Tilemaker-Skript: [scripts/tilemaker.sh](scripts/tilemaker.sh)
- Tilemaker z17 Config: [scripts/tilemaker/config-openmaptiles-z17.json](scripts/tilemaker/config-openmaptiles-z17.json)
- Raster-Renderer (Vektor -> PNG-MBTiles): [scripts/render_raster.py](scripts/render_raster.py)
- Hoehenlinien-Generator (DEM -> Kontur-MBTiles): [scripts/build_contours.sh](scripts/build_contours.sh)
- Experimenteller Renderer mit Benchmark-Fokus: [scripts/render_raster_test.py](scripts/render_raster_test.py)
- MapLibre Native Helper (persistent worker): [scripts/render_maplibre_native.js](scripts/render_maplibre_native.js)
- Valhalla Build/Runtime Anleitung: [docs/valhalla-offline-setup.md](docs/valhalla-offline-setup.md)

## MBTiles-Handling in der App

Die App liest beim Laden einer MBTiles-Datei folgende Metadaten:

- `format`
- `minzoom`
- `maxzoom`

Verhalten:

- `format = pbf`: Vektorpfad mit `VectorTileLayer`
- `format in {png,jpg,jpeg,webp}`: Rasterpfad mit `TileLayer`
- unbekanntes Format: Fehlermeldung in der UI

Wenn `minzoom`/`maxzoom` vorhanden sind, werden diese direkt als aktive Zoom-Grenzen verwendet.

## Style-Thema fuer Vektor-MBTiles (wichtig)

Die Datei [packages/local_map/assets/maps/style.json](packages/local_map/assets/maps/style.json) ist auf das von Tilemaker erzeugte OpenMapTiles-Schema ausgelegt.

Wichtig fuer sichtbare Vektor-Karten:

- Die in `source-layer` verwendeten Layernamen muessen zu den `vector_layers` in den MBTiles-Metadaten passen.
- Dieses Projekt nutzt Tilemaker mit OpenMapTiles-Schema (z. B. Layer wie `water`, `waterway`, `transportation`, `boundary`, `building`, `landuse`, `landcover`, `park`).
- Ein Style fuer ein anderes Schema (z. B. Shortbread) fuehrt zu leeren Kartenflaechen.

Offline-first Verhalten:

- Der Vektor-Style wird ausschliesslich lokal aus Assets geladen.
- Lade-Reihenfolge:
	1. [packages/local_map/assets/maps/style.json](packages/local_map/assets/maps/style.json) (Primary)
	2. [packages/local_map/assets/maps/style_second.json](packages/local_map/assets/maps/style_second.json) (Secondary)
	3. [packages/local_map/assets/maps/style_navigation.json](packages/local_map/assets/maps/style_navigation.json) (Navigation)
	4. internes Fallback-Theme
- Remote-Styles, Remote-Glyphs und Remote-Sprites sind nicht Teil des Standardpfads.
- Bei Inkompatibilitaet zwischen Style und MBTiles-Schema faellt die App auf ein internes Fallback-Theme zurueck.
- In der Kartenansicht kann der aktive lokale Vektor-Style ueber den Style-Chip oben rechts umgeschaltet werden.

Hinweis:

- Raster-MBTiles sind davon nicht betroffen und werden weiterhin ueber den Rasterpfad angezeigt.

## Abhaengigkeiten und Fork-Overrides

Das Projekt braucht fuer Flutter Map 8.x **zwei** Git-Overrides in
[pubspec.yaml](pubspec.yaml):

- `flutter_map_mbtiles` (Git-Override)
- `vector_map_tiles_mbtiles` (Git-Override)

Grund ist nicht `flutter_map` selbst, sondern `mbtiles`: die auf pub.dev
veroeffentlichten Versionen haengen an `mbtiles: ^0.4.0`, dieses Projekt nutzt
`^0.5.0`. `vector_map_tiles_mbtiles` 1.2.0 fordert zusaetzlich noch
`vector_map_tiles: ^8.0.0`. Solange upstream
([josxha/flutter_map_plugins](https://github.com/josxha/flutter_map_plugins))
nichts Neues veroeffentlicht - Stand dort ist September 2024 - bleiben die
beiden Overrides noetig.

`vector_map_tiles` kommt seit dem Upgrade auf 9.0.0-beta.13 **direkt von
pub.dev**. Der frueher noetige Fork mit sechs eigenen Commits zum
Cancellation-Handling ist entfallen: upstream hat das in den Betas 9 bis 13
selbst geloest, und im Routentest taucht keine unbehandelte
`CancellationException` mehr auf.

Wichtig fuer konsumierende Projekte: `dependency_overrides` wirken nur im
Root-Package und werden nicht transitiv vererbt. Die beiden Eintraege muessen
dort also wiederholt werden, siehe
[packages/local_map/README.md](packages/local_map/README.md).

## Lokale Tile-Erzeugung mit Tilemaker (z17)

Das Skript [scripts/tilemaker.sh](scripts/tilemaker.sh) erzeugt Vektor-MBTiles auf Basis einer z17-Konfiguration und kann optional in einem zweiten Schritt Raster-MBTiles rendern.

Eigenschaften des Skripts:

- prueft, ob Eingabedateien bereits vorhanden sind
- laedt nur fehlende Daten nach
- entpackt Natural-Earth-Daten nur, wenn Zielverzeichnis noch nicht vorhanden ist
- bricht standardmaessig ab, wenn Ausgabedatei bereits existiert
- erzwingt Neuaufbau mit `FORCE_REBUILD=1`
- unterstuetzt optionale Regionen `vogelsberg` und `braunschweig` fuer schnelle Test-Builds
- unterstuetzt optional `raster`/`--raster` fuer einen zweiten Schritt (PNG-MBTiles aus Vektor-MBTiles)
- startet am Ende automatisch die Valhalla-Tile-Generierung via [scripts/valhalla/build_valhalla_from_pbf.sh](scripts/valhalla/build_valhalla_from_pbf.sh)

Ausfuehrung:

```bash
cd scripts

# Vollstaendiges Deutschland-Build
./tilemaker.sh

# Nur Vogelsberg (Testgebiet Fulda/Vogelsberg, BBox 8.9,50.22,9.9,50.85)
# Erzeugt vogelsberg.mbtiles statt germany.mbtiles
./tilemaker.sh vogelsberg

# Braunschweig mit Umland (BBox 10.28,52.12,10.78,52.42)
# Erzeugt braunschweig.mbtiles statt germany.mbtiles
./tilemaker.sh braunschweig

# Vektor + Raster (zweite Datei mit PNG-Tiles)
./tilemaker.sh raster

# Vogelsberg Vektor + Raster
./tilemaker.sh vogelsberg raster

# Braunschweig Vektor + Raster
./tilemaker.sh braunschweig raster
```

Neuaufbau erzwingen:

```bash
cd scripts
FORCE_REBUILD=1 ./tilemaker.sh
FORCE_REBUILD=1 ./tilemaker.sh vogelsberg
FORCE_REBUILD=1 ./tilemaker.sh braunschweig
FORCE_REBUILD=1 ./tilemaker.sh raster
FORCE_REBUILD=1 ./tilemaker.sh vogelsberg raster
FORCE_REBUILD=1 ./tilemaker.sh braunschweig raster
```

## Hoehenlinien (Konturlinien)

Das Skript [scripts/build_contours.sh](scripts/build_contours.sh) erzeugt Vektor-MBTiles mit Hoehenlinien, die beim Raster-Rendering direkt in die PNG-Tiles eingebacken werden.

**Datenquelle:** `elevation-tiles-prod` GeoTIFF-DEM auf AWS (`https://s3.amazonaws.com/elevation-tiles-prod/geotiff/{z}/{x}/{y}.tif`). Das sind oeffentlich erreichbare Hoehenkacheln mit echten Hoehenwerten in Metern; im aktuellen Skript wird Zoom `12` verwendet.

**Voraussetzung:** Docker (GDAL und tippecanoe laufen in Containern – keine lokale Installation noetig). Verwendete Images:

- `ghcr.io/osgeo/gdal:ubuntu-small-latest`
- `klokantech/tippecanoe:latest`

**Pipeline (4 Schritte, je Skip-fähig):**

| Schritt | Tool | Ergebnis |
|---------|------|---------|
| 1 | Download + `gdalbuildvrt` + `gdal_translate` | `{region}_dem.tif` – DEM aus XYZ-Kacheln zusammengefuegt und auf BBox geclippt |
| 2 | `gdal_contour` | `{region}_contours.gpkg` – Linien alle 10 m |
| 3 | `ogr2ogr` | `{region}_contours.geojson` |
| 4 | `tippecanoe` | `{region}_contours.mbtiles` – z9–z14 |

Hinweise zum Cache-/Rebuild-Verhalten:

- DEM-Kacheln werden regionsbezogen unter `map/tiles-germany/dem_tiles/<region>/z12/` gecacht.
- `FORCE_REBUILD=1` loescht auch alle Zwischenprodukte (`*_dem.tif`, `*_contours.gpkg`, `*_contours.geojson`, finale MBTiles und den regionalen DEM-Cache`) und baut den kompletten Konturlinien-Stack neu auf.
- Leere oder ungueltige Zwischenprodukte werden vom Skript automatisch erkannt und neu erzeugt.

Ausfuehrung:

```bash
cd scripts

# Vogelsberg (Standard)
./build_contours.sh vogelsberg

# Braunschweig
./build_contours.sh braunschweig

# Deutschland (mehrere GB DEM, langsam)
./build_contours.sh germany
```

Optionale Umgebungsvariablen:

- `CONTOUR_INTERVAL` – Hoehenlinien-Abstand in Metern (Standard: `10`)
- `CONTOUR_MINZOOM` – Tippecanoe Minzoom (Standard: `9`)
- `CONTOUR_MAXZOOM` – Tippecanoe Maxzoom (Standard: `14`)
- `FORCE_REBUILD=1` – Alle Zwischendateien neu erzeugen

```bash
# 20-m-Intervall statt 10 m
CONTOUR_INTERVAL=20 ./build_contours.sh vogelsberg

# Neuaufbau erzwingen
FORCE_REBUILD=1 ./build_contours.sh vogelsberg
```

**Hoehenlinien in Raster-Tiles einbacken:**

Nach der Erzeugung der Kontur-MBTiles werden diese beim Raster-Rendering ueber `RASTER_CONTOURS` eingebunden. Der Renderer (`render_raster.py`) injiziert die Linien automatisch in den MapLibre-Style, sodass sie in jedem PNG-Tile sichtbar sind.

Dargestellte Layer (via `_inject_contour_layers_into_style`):

- **Minor-Linien** (jede 10 m, ausser 100-m-Vielfache): grau, 0.5 px, ab z11
- **Major-Linien** (jede 100 m): dunkelgrau, 1.2 px, ab z11
- **Beschriftungen** (jede 100 m): Hoehenangabe in Metern entlang der Linie, ab z12

```bash
# Vollstaendiger Workflow Vogelsberg:

# 1. Konturlinien erzeugen
./build_contours.sh vogelsberg

# 2. Vektor + Raster mit eingebackenen Hoehenlinien
RASTER_CONTOURS=vogelsberg_contours.mbtiles ./tilemaker.sh vogelsberg raster

# Kompletter Neuaufbau der Konturlinien-Zwischenprodukte
FORCE_REBUILD=1 ./build_contours.sh vogelsberg
```

Ohne `RASTER_CONTOURS` werden Raster-Tiles wie bisher ohne Hoehenlinien erzeugt.

Ausgabedateien (in `map/tiles-germany/`):

- `{region}_dem.tif` – geclipptes DEM (Zwischenprodukt)
- `{region}_contours.gpkg` – GeoPackage (Zwischenprodukt)
- `{region}_contours.geojson` – GeoJSON (Zwischenprodukt)
- `{region}_contours.mbtiles` – **fertige Vektor-MBTiles fuer den Raster-Schritt**

## Offline-Indizierung und Ortssuche

Nach der Erzeugung von Vektor-MBTiles mit Tilemaker wird automatisch eine SQLite-Datenbank mit searchable place names erzeugt.

**Workflow:**

1. **MVT-Protobuf-Dekompression**: Das Skript [scripts/extract_names_to_sqlite.py](scripts/extract_names_to_sqlite.py) liest die gzip-komprimierten Mapbox-Vector-Tile-Blobs aus den MBTiles.
2. **Protobuf-Dekodierung**: Dekodiert das MVT-Protobuf-Format und extrahiert bekannte Name-Felder (`name`, `name:de`, `name:en`, `name:latin`) aus relevanten Layern.
3. **Koordinaten-Transformation**: Berechnet aus der Feature-Geometrie eine repräsentative WGS84-Position mittels Web-Mercator-Projektion.
4. **FTS5-Indizierung**: Erstellt einen Full-Text-Search-Index für schnelle Substring-Suches.

**Suchpriorisierung** in der App:

- `place` (Orte, Städte, Regionen) — höchste Priorität
- `poi` (Points of Interest, Sehenswürdigkeiten)
- `mountain_peak` (Berge, Gipfel)
- `water_name` (Seen, Flüsse, Gewässer)
- `transportation_name` (Straßen, Routen) — niedrigste Priorität

Das [OfflineGeocoder](packages/local_map/lib/src/services/offline_geocoder.dart)-Service nutzt `searchPrioritized()` für typsortierte Suchergebnisse. Die [PlaceSearchBar](packages/local_map/lib/src/widgets/search_bar.dart)-Widget zeigt eine Autocomplete-Dropdown mit Typ-Icons und sortiert nach Priorität.

**Wichtig:** Die Namen-DB wird automatisch als `{basename}_names.db` neben der MBTiles-Datei erzeugt (z.B. `vogelsberg_names.db` fuer `vogelsberg.mbtiles` oder `braunschweig_names.db` fuer `braunschweig.mbtiles`). Die App lädt sie beim Starten automatisch über `OfflineGeocoder.initialize()`.

**Technische Details:**

- **Format**: MBTiles Blobs enthalten GZip-komprimierte MVT-Protobuf-Daten
- **Dekompression**: Automatische GZip-Dekompression vor MVT-Dekodierung
- **Geometrie-Transformation**: MVT-Pixelkoordinaten (0-4096) → Web Mercator → WGS84 (EPSG:4326)
- **Koordinaten-System**: MBTiles nutzt TMS-Konvention (inverte Y-Achse), wird zu XYZ konvertiert
- **Gesamtertrag vogelsberg.mbtiles**: 27.062 unique place names aus 140.535 tiles (z0-z17)

Ausgabedateien:

- nur Vektor: `germany.mbtiles`, `vogelsberg.mbtiles` oder `braunschweig.mbtiles`
- mit Raster-Schritt: zusaetzlich `germany_raster.mbtiles`, `vogelsberg_raster.mbtiles` oder `braunschweig_raster.mbtiles`

## Offline-Routing mit Valhalla

Die Kartenanzeige und das Routing sind im Projekt bewusst getrennt:

- Kartenanzeige: MBTiles (Raster/Vektor) in Flutter
- Routing: lokaler Valhalla-HTTP-Service (z. B. auf `127.0.0.1:8002`)

Wichtig:

- Raster-/Vektor-MBTiles enthalten keine Routing-Engine.
- Valhalla benoetigt eigene, vorberechnete Routing-Daten aus OSM-PBF.
- Beide Pipelines koennen denselben OSM-Extrakt nutzen, aber die Datenprodukte sind unterschiedlich.

Konkrete Setup-Schritte (Build + Pi Runtime + Testrequest) stehen in:

- [docs/valhalla-offline-setup.md](docs/valhalla-offline-setup.md)

Raster-Schritt (optional) nutzt [scripts/render_raster.py](scripts/render_raster.py) und einen lokalen `tileserver-gl` Docker-Container mit dem Navigation-Style aus [packages/local_map/assets/maps/style_navigation.json](packages/local_map/assets/maps/style_navigation.json).

Optionale Umgebungsvariablen fuer den Raster-Schritt:

- `RASTER_MAXZOOM` (Standard: `17`)
- `RASTER_WORKERS` (Standard: `8`)

Hinweis: Die z17-Config erhoeht Detail-Layer bis Zoom 17 inklusive Hausnummern (`housenumber`-Layer ab z14). Das verbessert Details, vergroessert aber Datenmenge und Build-Zeit.

## Experimenteller Renderer-Test (MapLibre Worker)

Fuer schnelle Vergleiche zwischen `tileserver_gl` und `maplibre_native` gibt es den separaten Testpfad in [scripts/render_raster_test.py](scripts/render_raster_test.py). Dieser aendert [scripts/render_raster.py](scripts/render_raster.py) nicht.

Wichtig:

- Input muss ein **Vektor-MBTiles** mit `format=pbf` sein.
- Raster-MBTiles (`png`, `jpg`, `webp`) sind fuer den `maplibre_native`-Pfad nicht gueltig.
- Der Node-Helper [scripts/render_maplibre_native.js](scripts/render_maplibre_native.js) nutzt einen persistenten Worker (kein Node-Neustart pro Tile).
- Der Node-Helper nutzt file-basiertes SQLite ueber `better-sqlite3` (kein komplettes In-Memory-Laden grosser MBTiles).
- Fehlende Vektor-Tiles werden als leere Tile behandelt (kein harter Render-Abbruch).

Einmaliges Setup:

```bash
cd scripts
npm install
```

Abhaengigkeiten pruefen:

```bash
cd scripts
npm ls --depth=0
```

Erwartet fuer den MapLibre-Pfad:

- `@maplibre/maplibre-gl-native`
- `better-sqlite3`

Smoke-Test (Dry-Run):

```bash
cd ..
python scripts/render_raster_test.py map/test/vogelsberg.mbtiles --maxzoom 12 --renderer auto --dry-run
```

Beispiel-Benchmark (fairer Vergleich, gleiche Stichprobe):

```bash
# MapLibre Native (persistent worker)
python scripts/render_raster_test.py map/test/vogelsberg.mbtiles --maxzoom 14 --renderer maplibre_native --sample-tiles 500 --maplibre-workers 4

# TileServer GL
python scripts/render_raster_test.py map/test/vogelsberg.mbtiles --maxzoom 14 --renderer tileserver_gl --sample-tiles 500
```

Empfehlungen aus den bisherigen Messungen (Vogelsberg, Sample 500):

- Bestes Setting: `--maplibre-workers 4`
- `maplibre_native` war in diesem Setup schneller als `tileserver_gl`
- Zu viele Worker (z. B. 6 oder 8) reduzierten den Durchsatz

Hinweis zu Hessen-Dateien:

- [map/tiles-germany/hessen.mbtiles](map/tiles-germany/hessen.mbtiles) ist Raster (`format=png`) und daher kein gueltiger Input fuer `maplibre_native`.

Beispiel mit grosser Datei (Germany, Sample):

```bash
python scripts/render_raster_test.py map/tiles-germany/germany.mbtiles --maxzoom 17 --sample-tiles 5000 --renderer maplibre_native --maplibre-workers 4
```

## Projektstruktur

Die Kartenfunktionalitaet liegt als eigenstaendiges Flutter-Package unter
[packages/local_map/](packages/local_map/) und kann von anderen Projekten
eingebunden werden. Die App im Repository-Root ist die Demo-/Referenz-App
dazu und bindet das Package per `path:`-Dependency ein.

```
flutter_local_map/
├── lib/main.dart          App-Shell (Menue, Download-Flow, Theme)
├── test/                  Tests, die echte MBTiles unter map/ brauchen
├── packages/local_map/    Die Bibliothek
│   ├── lib/local_map.dart Oeffentliche API (Barrel-Export)
│   ├── lib/src/           config/ services/ widgets/
│   ├── assets/maps/       Vektor-Styles
│   └── test/              Unit-/Widget-Tests der Bibliothek
├── map/                   Kartendaten (nicht im Git)
└── scripts/               Tilemaker, Valhalla, Geocoder-Extraktion
```

Einbinden in ein anderes Projekt, Konfiguration und oeffentliche API sind in
[packages/local_map/README.md](packages/local_map/README.md) beschrieben.
Wichtig dabei: die drei `dependency_overrides` aus [pubspec.yaml](pubspec.yaml)
muessen ins konsumierende Projekt kopiert werden, sie werden von pub nicht
transitiv vererbt.

Tests der Bibliothek laufen separat:

```bash
cd packages/local_map && flutter test
```

## Konfiguration

Relevante Einstellungen in [packages/local_map/lib/src/config/map_config.dart](packages/local_map/lib/src/config/map_config.dart). `MapConfig` ist eine
uebergebbare Instanz; `MapConfig.hessen` enthaelt das Setup dieses Projekts und
wird in [lib/main.dart](lib/main.dart) via `LocalMap.ensureInitialized()`
als Default gesetzt:

- Bounding-Box (`cameraBounds`, hier Hessen; `null` = keine Begrenzung)
- initiale Zoom-Werte (Fallback, MBTiles-Metadaten haben Vorrang)
- Download-URL und Dateiname
- Speicherort-Strategie fuer Offline-Daten
- Vektor-Styles, Valhalla-Endpunkt, GPS-Tourdatei
- Vektor-Speicherbudget: `memoryTileCacheMaxSize`, `memoryTileDataCacheMaxSize`,
  `textCacheMaxSize`, `vectorConcurrency`, `vectorLayerMode`

## Zielplattform und Betriebsgrenzen

Zielgeraet ist ein **Raspberry Pi mit 4 GB RAM**. Ein 2-GB-Pi reicht nicht, weil
neben der App auch die Valhalla-Routing-Engine auf demselben Geraet laeuft.
Speicher- und Performancemessungen sind immer gegen dieses Budget zu bewerten.

Gemessen (Release-Build, Vektorkarte, GPS-Route bei Maximalzoom 17, Stand
2026-09-22): **~400 MB** Arbeitsspeicher. Sparsame Cache-Einstellungen
(`memoryTileCacheMaxSize` 2 MB, `memoryTileDataCacheMaxSize` 6,
`textCacheMaxSize` 30, `vectorConcurrency` 2) aendern daran nichts
(402 vs. 411 MB) und sind deshalb nicht noetig.

Die Anwendung arbeitet vollstaendig offline. Verifiziert wurde das in einem
eigenen Netzwerk-Namespace (`unshare -rn`) ohne jede Verbindung; der einzige
Netzwerkzugriff ueberhaupt ist die Valhalla-Abfrage auf `127.0.0.1:8002`.

## Betrieb auf eingebettetem Linux (emb_cli / ivi-homescreen)

Cross-Builds fuer den Pi entstehen mit **`emb_cli`** und laufen unter
**ivi-homescreen** mit dem Backend `drm-kms-egl`, also ohne X11 und ohne
Wayland-Compositor. Das Flutter-Bundle bringt die App mit, **nicht** aber die
Dinge, die eine Desktop-Distribution sonst beisteuert. Auf einem schlanken
Image (RaspiOS Lite, Yocto, Buildroot) fehlen sie, und jede Luecke sieht
zunaechst wie ein Fehler der Karte aus.

### Schriftarten sind Pflicht

**Ohne installierte Schriftart zeichnet Skia keinen einzigen Buchstaben.** Die
Karte erscheint dann vollstaendig ohne Beschriftung: Geometrie, Flaechen und
Linien sind da, Orts- und Strassennamen fehlen restlos. Es gibt dazu weder
eine Fehlermeldung noch eine Logzeile - Flutter hat schlicht keinen Glyphen,
auf den es zurueckfallen kann.

RaspiOS Lite hat kein `/usr/share/fonts`. Auf dem Zielgeraet also:

```bash
sudo apt install -y fonts-dejavu-core
```

Das genuegt fuer deutsche Karten. Wer mehr Schriftsysteme braucht, nimmt
`fonts-noto-core`. Pruefen laesst sich das ohne die App:

```bash
find /usr/share/fonts -type f \( -name '*.ttf' -o -name '*.otf' \) | wc -l
```

Steht dort `0` oder existiert das Verzeichnis nicht, fehlt die Beschriftung
garantiert. Fuer ein Kiosk-Image ist die robustere Variante, eine Schrift als
Flutter-Asset ins Bundle zu nehmen (`fonts:` in der `pubspec.yaml` plus
`ThemeData.fontFamily`) - dann haengt die App nicht an der Ausstattung des
Systems.

### Mauszeiger braucht ein XCursor-Theme

Ohne Cursor-Theme meldet der Embedder beim Start:

```
[DrmCursor] no XCursor theme found (No such file or directory); no cursor sprite
```

Der Zeiger existiert dann, ist aber unsichtbar - man zielt blind, und das
sieht aus, als kaeme die Eingabe nicht an. Abhilfe:

```bash
sudo apt install -y adwaita-icon-theme
./homescreen -b . -f -t Adwaita
```

Danach steht `[DrmCursor] ready (sprite=24px ...)` im Log.

### Weitere Laufzeitvoraussetzungen

- Laufzeitpakete: `libegl1 libgles2 libgbm1 libseat1 libdisplay-info2
  libinput10 libxkbcommon0`
- `seatd` aktiv (`systemctl enable --now seatd`), sonst haengt `drm-kms-egl`
  ueber SSH ohne Fehlermeldung an `libseat`.
- **Immer mit `-f` starten.** Die Zeile `Size: 1920 x 720` im Log ist der
  Default der View-Konfiguration, nicht die Monitoraufloesung; ohne `-f`
  laeuft die View kleiner als der Scanout. `--drm-list-modes` zeigt die Modi
  des angeschlossenen Geraets.
- **Displayaufloesung:** Beim Waveshare 7" HDMI LCD (H) verwirft der
  vc4-Treiber den bevorzugten 1024x600-Modus des Panels, weil dessen Timings
  ungerade sind - das Panel bekommt dann 1920x1080 und skaliert herunter,
  Beschriftungen werden unleserlich. Loesung ohne `vc4-fkms-v3d`:
  [docs/waveshare-1024x600-full-kms.md](docs/waveshare-1024x600-full-kms.md).
- Routing: Die App fragt `http://127.0.0.1:8002` ab. Laeuft dort kein
  Valhalla, meldet die Oberflaeche "Valhalla nicht zu erreichen" - siehe
  [docs/valhalla-offline-setup.md](docs/valhalla-offline-setup.md).
- Die MBTiles liegen auf dem Geraet unter
  `~/.local/share/homescreen/offline_maps/`. Der Dateiname sagt nichts ueber
  den Inhalt: die Startposition muss in den `bounds` der Datei liegen, sonst
  bleibt die Karte leer (die App korrigiert das inzwischen und schreibt eine
  Zeile ins Log).

## Troubleshooting

### Vektorkarte ruckelt oder friert ein

**Zuerst den Buildmodus pruefen.** `vector_map_tiles` benutzt `executor_lib`,
und dort gilt:

```dart
Executor newExecutor({required int concurrency}) =>
    kDebugMode ? QueueExecutor() : PoolExecutor(concurrency: concurrency);
```

Im Debug-Modus werden **keine Isolates** verwendet - Parsen und Rendern aller
Kacheln laufen auf dem Main-Isolate, und ein Backtrace waehrend einer Blockade
landete entsprechend in der Dart-Garbage-Collection. Vektor-Performance
deshalb immer mit `flutter run --release` oder `--profile` messen, nie mit dem
Standard-`flutter run`.

**Richtig messen.** Wanduhr-Abstaende zwischen `Timer.periodic`-Ticks taugen
dafuer nicht: unter WSL2/WSLg zeigt eine leere Flutter-App ohne jede Karte
dieselben Aussetzer von mehreren Sekunden, dort wird der Prozess von der
Umgebung ausgebremst. Aussagekraeftig ist nur
`SchedulerBinding.instance.addTimingsCallback`, das die echten Frame-Zeiten
der Engine liefert.

So gemessen (Release, Vektorkarte, GPS-Route bei Zoom 17, 258 s):
schlechtester Frame **112 ms Build + 171 ms Raster**, 256 ms Gesamtspanne.
Ein sichtbarer Ruckler beim Nachladen neuer Kacheln, kein Einfrieren.

### Keine Karte sichtbar

- Pruefen, ob MBTiles-Datei vorhanden ist
- Format in MBTiles-Metadaten pruefen (`pbf` oder Rasterformat)
- Download-URL und Speicherpfad in [packages/local_map/lib/src/config/map_config.dart](packages/local_map/lib/src/config/map_config.dart) pruefen
- **Liegt die Kameraposition ueberhaupt im Abdeckungsbereich der MBTiles?**
  Die `bounds` aus den Metadaten pruefen. Ein Koordinatenfehler faellt als
  leere Karte auf, nicht als Fehlermeldung - genau so verbarg sich ein
  Umrechnungsfehler im NMEA-Parser des GPS-Simulators, der die Kamera auf
  15,36 statt 9,36 Grad Ost schickte und damit aus `hessen.mbtiles` heraus.
  Die App faengt das inzwischen ab: liegt die Startposition ausserhalb der
  `bounds`, rueckt sie in die Mitte der Kacheln und schreibt
  `[MapError] ERROR [Camera bounds]: ...` ins Log - auch im Release. Steht die
  Zeile da, passen Datei und erwartetes Gebiet nicht zusammen; der Dateiname
  allein sagt darueber nichts.

### Vektorlabels fehlen

- **Auf eingebetteten Zielen zuerst die Schriftarten pruefen.** Fehlt auf dem
  Geraet jede Schrift, zeichnet Skia keinen Buchstaben und die Karte bleibt
  komplett ohne Beschriftung - ohne Fehlermeldung. Siehe
  [Betrieb auf eingebettetem Linux](#betrieb-auf-eingebettetem-linux-emb_cli--ivi-homescreen).
  Gegenprobe: dieselbe MBTiles-Datei und derselben Style lokal starten. Ist die
  Schrift dort da, liegt es am Zielsystem, nicht an Style oder Kacheln.
- Die lokalen Styles enthalten Label-Layer fuer `place`, `transportation_name` und `water_name`.
- Erscheinen einzelne Labels nicht, auf den zweiten Style umschalten und die
  Logs in [packages/local_map/lib/src/widgets/map_view.dart](packages/local_map/lib/src/widgets/map_view.dart) pruefen.

### Zoom scheint begrenzt

- Effektive Zoom-Grenzen kommen aus MBTiles-Metadaten
- Bei Tilemaker bestimmt die verwendete Config den `maxzoom`

### maplibre_native startet nicht (libOpenGL/libuv Fehler)

- Typische Meldungen: `libOpenGL.so.0` oder `libuv.so.1` fehlen.
- Ubuntu-Fix:

```bash
sudo apt update
sudo apt install -y libopengl0 libuv1
```

- Optional pruefen:

```bash
ldconfig -p | grep -E 'libOpenGL.so.0|libuv.so.1'
```

## Build

```bash
flutter build windows --release
# oder
flutter build linux --release
```

## Changelog (Kurz)

- 2026-04: `maplibre_native` in [scripts/render_raster_test.py](scripts/render_raster_test.py) auf robusten Large-MBTiles-Betrieb aktualisiert.
- 2026-04: Node-Helper [scripts/render_maplibre_native.js](scripts/render_maplibre_native.js) nutzt jetzt `better-sqlite3` (file-basiert) statt `sql.js` In-Memory-Load.
- 2026-04: Ubuntu-Hinweise fuer `libopengl0` und `libuv1` sowie Python-Pakete (`python3-requests`, `python3-tqdm`) dokumentiert.

## Lizenz und Daten

- Code: siehe Projektlizenz
- Kartendaten: OpenStreetMap (ODbL), Attribution erforderlich: `© OpenStreetMap contributors`
