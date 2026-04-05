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
- Tilemaker-Skript: [scripts/tilemaker.sh](scripts/tilemaker.sh)
- Tilemaker z16 Config: [scripts/tilemaker/config-openmaptiles-z16.json](scripts/tilemaker/config-openmaptiles-z16.json)

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
	3. internes Fallback-Theme
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

## Lokale Tile-Erzeugung mit Tilemaker (z16)

Das Skript [scripts/tilemaker.sh](scripts/tilemaker.sh) erzeugt `germany.mbtiles` auf Basis einer z16-Konfiguration.

Eigenschaften des Skripts:

- prueft, ob Eingabedateien bereits vorhanden sind
- laedt nur fehlende Daten nach
- bricht standardmaessig ab, wenn Ausgabedatei bereits existiert
- erzwingt Neuaufbau mit `FORCE_REBUILD=1`

Ausfuehrung:

```bash
cd scripts
./tilemaker.sh
```

Neuaufbau erzwingen:

```bash
cd scripts
FORCE_REBUILD=1 ./tilemaker.sh
```

Hinweis: Die z16-Config erhoeht gezielt Detail-Layer bis Zoom 16. Das verbessert Details, vergroessert aber Datenmenge und Build-Zeit.

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

## Build

```bash
flutter build windows --release
# oder
flutter build linux --release
```

## Lizenz und Daten

- Code: siehe Projektlizenz
- Kartendaten: OpenStreetMap (ODbL), Attribution erforderlich: `© OpenStreetMap contributors`
