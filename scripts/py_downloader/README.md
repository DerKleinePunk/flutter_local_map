# Scripts für Tile-Generierung

Dieses Verzeichnis enthält Scripts zum Herunterladen und Erstellen der MBTiles-Datei für die Region Hessen.

## Verfügbare Scripts

### 1. download_tiles.py (Haupt-Script)

Python-Script, das die OpenStreetMap-Tiles herunterlädt und als MBTiles-Datei speichert.

**Voraussetzungen:**
```bash
pip install download-tiles
```

**Verwendung:**
```bash
python download_tiles.py
```

**Konfiguration:**
- Region: Hessen, Deutschland
- Bounding Box: 7.7726,49.3963,10.2358,51.6569 (West,Süd,Ost,Nord)
- Zoom-Level: 10-14
- Output: hessen.mbtiles (~150-300 MB)

### 2. download_hessen_tiles.bat (Windows)

Windows Batch-Script mit interaktiver Installation und Fortschrittsanzeige.

**Verwendung:**
```cmd
download_hessen_tiles.bat
```

Das Script:
- Prüft ob Python installiert ist
- Installiert automatisch `download-tiles` falls nicht vorhanden
- Führt den Download aus
- Zeigt den Status an

### 3. download_hessen_tiles.sh (Linux/Mac)

Shell-Script für Linux und macOS.

**Verwendung:**
```bash
chmod +x download_hessen_tiles.sh
./download_hessen_tiles.sh
```

## Schnellstart

### Windows
1. Doppelklick auf `download_hessen_tiles.bat`
2. Bei Bedarf `download-tiles` installieren lassen
3. Warten bis Download abgeschlossen ist (~30-60 Minuten)

### Linux/Mac
```bash
chmod +x download_hessen_tiles.sh
./download_hessen_tiles.sh
```

### Manuell (alle Plattformen)
```bash
# Python-Paket installieren
pip install download-tiles

# Script ausführen
python download_tiles.py
```

## Download-Details

**Erwartete Dauer:** 30-60 Minuten (abhängig von Internetgeschwindigkeit)  
**Datenmenge:** ~250 MB Download  
**Dateigröße:** ~150-300 MB (komprimiert in MBTiles)  
**Tiles:** Mehrere tausend einzelne Kartenkacheln

## Tile-Server

Standard: https://tile.openstreetmap.org/{z}/{x}/{y}.png

**Wichtig:** Beachten Sie die OpenStreetMap Tile Usage Policy:
- Setzen Sie einen sinnvollen User-Agent
- Vermeiden Sie zu viele parallele Anfragen
- Attribution erforderlich: © OpenStreetMap contributors

## Anpassungen

Sie können die Konfiguration in `download_tiles.py` anpassen:

```python
CONFIG = {
    "region_name": "Hessen",
    "bbox": "7.7726,49.3963,10.2358,51.6569",  # Ihre Bounding Box
    "zoom_levels": "10-14",                     # Zoom-Bereich
    "output_file": "hessen.mbtiles",           # Ausgabedatei
    "tile_server": "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
    "attribution": "© OpenStreetMap contributors",
}
```

### Andere Regionen herunterladen

Bounding Box für andere Regionen finden:
- https://boundingbox.klokantech.com/
- https://www.openstreetmap.org/export

Beispiel für Frankfurt:
```python
"bbox": "8.4,50.0,8.8,50.2",  # Frankfurt
"zoom_levels": "12-16",        # Mehr Detail für kleinere Region
```

## Fehlerbehebung

### "download-tiles nicht gefunden"
```bash
pip install download-tiles
```

### "Rate Limit überschritten"
Zu viele Anfragen an den OSM-Server. Warten Sie einige Minuten und versuchen Sie es erneut.

### "Datei zu klein"
Download möglicherweise fehlgeschlagen. Datei löschen und erneut versuchen:
```bash
rm hessen.mbtiles
python download_tiles.py
```

### Cache verwenden für schnellere Wiederholungen
```bash
# Windows
set TILES_CACHE_DIR=C:\temp\tiles_cache
python download_tiles.py

# Linux/Mac
export TILES_CACHE_DIR=/tmp/tiles_cache
python download_tiles.py
```

## Validierung

Nach dem Download können Sie die MBTiles-Datei validieren:

```bash
# Mit SQLite
sqlite3 hessen.mbtiles "SELECT * FROM metadata;"
sqlite3 hessen.mbtiles "SELECT COUNT(*) FROM tiles;"

# Mit Python
python -c "from mbtiles import MbTiles; mb = MbTiles('hessen.mbtiles'); print(mb.metadata())"
```

## In Flutter-App verwenden

Nach erfolgreichem Download:

1. Kopieren Sie `hessen.mbtiles` in das `assets/maps/` Verzeichnis
2. Oder hosten Sie die Datei in Azure Blob Storage
3. Aktualisieren Sie die Download-URL in `lib/config/map_config.dart`

```dart
static const String downloadUrl = 
    'https://your-storage.blob.core.windows.net/map-tiles/hessen.mbtiles';
```

## Performance-Tipps

- **Parallele Downloads:** Das Script lädt standardmäßig nicht parallel, um den Server nicht zu überlasten
- **Cache:** Verwenden Sie `TILES_CACHE_DIR` für schnellere wiederholte Builds
- **Zoom-Level:** Weniger Zoom-Levels = kleinere Datei, schnellerer Download
- **Kleinere Region:** Reduzieren Sie die Bounding Box für Tests

## Lizenz

Die heruntergeladenen OpenStreetMap-Daten unterliegen der **Open Database License (ODbL)**.

Attribution erforderlich:
```
© OpenStreetMap contributors
```

Weitere Informationen: https://www.openstreetmap.org/copyright
