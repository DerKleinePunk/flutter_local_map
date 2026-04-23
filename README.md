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

- App-Konfiguration: [lib/config/map_config.dart](lib/config/map_config.dart)
- Karten-Widget: [lib/widgets/map_view.dart](lib/widgets/map_view.dart)
- Download-Service: [lib/services/map_downloader.dart](lib/services/map_downloader.dart)
- Routing-Service (Valhalla HTTP): [lib/services/valhalla_routing_service.dart](lib/services/valhalla_routing_service.dart)
- Valhalla Build-Skript (optional mit BBox): [scripts/valhalla/build_valhalla_from_pbf.sh](scripts/valhalla/build_valhalla_from_pbf.sh)
- Valhalla Run-Skript (lokaler Server): [scripts/valhalla/run_valhalla_server.sh](scripts/valhalla/run_valhalla_server.sh)
- Valhalla Build-Skript fuer Windows/Pwsh: [scripts/valhalla/build_valhalla_from_pbf.ps1](scripts/valhalla/build_valhalla_from_pbf.ps1)
- Valhalla Run-Skript fuer Windows/Pwsh: [scripts/valhalla/run_valhalla_server.ps1](scripts/valhalla/run_valhalla_server.ps1)
- Tilemaker-Skript: [scripts/tilemaker.sh](scripts/tilemaker.sh)
- Tilemaker z17 Config: [scripts/tilemaker/config-openmaptiles-z17.json](scripts/tilemaker/config-openmaptiles-z17.json)
- Raster-Renderer (Vektor -> PNG-MBTiles): [scripts/render_raster.py](scripts/render_raster.py)
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

Die Datei [assets/maps/style.json](assets/maps/style.json) ist auf das von Tilemaker erzeugte OpenMapTiles-Schema ausgelegt.

Wichtig fuer sichtbare Vektor-Karten:

- Die in `source-layer` verwendeten Layernamen muessen zu den `vector_layers` in den MBTiles-Metadaten passen.
- Dieses Projekt nutzt Tilemaker mit OpenMapTiles-Schema (z. B. Layer wie `water`, `waterway`, `transportation`, `boundary`, `building`, `landuse`, `landcover`, `park`).
- Ein Style fuer ein anderes Schema (z. B. Shortbread) fuehrt zu leeren Kartenflaechen.

Offline-first Verhalten:

- Der Vektor-Style wird ausschliesslich lokal aus Assets geladen.
- Lade-Reihenfolge:
	1. [assets/maps/style.json](assets/maps/style.json) (Primary)
	2. [assets/maps/style_second.json](assets/maps/style_second.json) (Secondary)
	3. [assets/maps/style_navigation.json](assets/maps/style_navigation.json) (Navigation)
	4. internes Fallback-Theme
- Remote-Styles, Remote-Glyphs und Remote-Sprites sind nicht Teil des Standardpfads.
- Bei Inkompatibilitaet zwischen Style und MBTiles-Schema faellt die App auf ein internes Fallback-Theme zurueck.
- In der Kartenansicht kann der aktive lokale Vektor-Style ueber den Style-Chip oben rechts umgeschaltet werden.

Hinweis:

- Raster-MBTiles sind davon nicht betroffen und werden weiterhin ueber den Rasterpfad angezeigt.

## Abhaengigkeiten und Fork-Overrides

Das Projekt nutzt fuer Flutter Map 8.x Fork-Overrides in [pubspec.yaml](pubspec.yaml):

- `flutter_map_mbtiles` (Git-Override)
- `vector_map_tiles_mbtiles` (Git-Override)
- `vector_map_tiles` (Git-Override, Branch `9.0.0-beta.8`)

Damit sind die benoetigten Anpassungen fuer den aktuellen Stack im Projekt fixiert.

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

Das [OfflineGeocoder](lib/services/offline_geocoder.dart)-Service nutzt `searchPrioritized()` für typsortierte Suchergebnisse. Die [PlaceSearchBar](lib/widgets/search_bar.dart)-Widget zeigt eine Autocomplete-Dropdown mit Typ-Icons und sortiert nach Priorität.

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

Raster-Schritt (optional) nutzt [scripts/render_raster.py](scripts/render_raster.py) und einen lokalen `tileserver-gl` Docker-Container mit dem Navigation-Style aus [assets/maps/style_navigation.json](assets/maps/style_navigation.json).

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

## Konfiguration

Relevante Einstellungen in [lib/config/map_config.dart](lib/config/map_config.dart):

- Hessen-Bounding-Box
- initiale Zoom-Werte (Fallback)
- Download-URL und Dateiname
- Speicherort-Strategie fuer Offline-Daten

## Troubleshooting

### Keine Karte sichtbar

- Pruefen, ob MBTiles-Datei vorhanden ist
- Format in MBTiles-Metadaten pruefen (`pbf` oder Rasterformat)
- Download-URL und Speicherpfad in [lib/config/map_config.dart](lib/config/map_config.dart) pruefen

### Vektorlabels fehlen

- Die lokalen Styles enthalten Label-Layer fuer `place`, `transportation_name` und `water_name`.
- Wenn trotzdem keine Labels erscheinen, ist meist das zugrunde liegende Rendering (z. B. fehlende Glyph-Unterstuetzung) die Ursache.
- In diesem Fall auf den zweiten Style umschalten und Logs in [lib/widgets/map_view.dart](lib/widgets/map_view.dart) pruefen.

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

## Lizenz und Daten

- Code: siehe Projektlizenz
- Kartendaten: OpenStreetMap (ODbL), Attribution erforderlich: `© OpenStreetMap contributors`
