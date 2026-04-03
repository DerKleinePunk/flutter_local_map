#!/usr/bin/env python3
"""
Script zum Herunterladen von OpenStreetMap-Tiles für Hessen
und Speichern als MBTiles-Datei für Offline-Nutzung.

Eigene Implementierung ohne externe Dependencies (außer requests + tqdm).
Kompatibel mit Python 3.12+

Installation: pip install requests tqdm

Autor: Generiert von GitHub Copilot
Datum: 2026-04-01
"""

import sys
import sqlite3
import math
import time
from pathlib import Path
from typing import Tuple, List, TypedDict
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    import requests
    from tqdm import tqdm
except ImportError:
    print("✗ Fehler: Benötigte Pakete nicht installiert.")
    print("\nInstallation mit: pip install requests tqdm")
    sys.exit(1)

# Konfiguration für Hessen
class ConfigDict(TypedDict):
    region_name: str
    bbox: Tuple[float, float, float, float]
    zoom_min: int
    zoom_max: int
    output_file: str
    tile_server: str
    attribution: str
    description: str
    user_agent: str
    max_workers: int
    rate_limit_delay: float
    retry_attempts: int
    timeout: int


CONFIG: ConfigDict = {
    "region_name": "Hessen",
    "bbox": (7.7726, 49.3963, 10.2358, 51.6569),  # West, Süd, Ost, Nord
    "zoom_min": 10,
    "zoom_max": 14,
    "output_file": "hessen.mbtiles",
    "tile_server": "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
    "attribution": "© OpenStreetMap contributors",
    "description": "Offline-Kartendaten für Hessen, Deutschland",
    "user_agent": "OfflineMapApp/1.0 (Educational/Testing Purpose)",
    "max_workers": 2,  # Maximal 2 parallele Downloads (OSM Policy!)
    "rate_limit_delay": 0.5,  # Mindestens 500ms zwischen Requests
    "retry_attempts": 3,
    "timeout": 30,
}


def lon_to_tile_x(lon: float, zoom: int) -> int:
    """Konvertiert Longitude zu Tile X-Koordinate."""
    return int((lon + 180.0) / 360.0 * (1 << zoom))


def lat_to_tile_y(lat: float, zoom: int) -> int:
    """Konvertiert Latitude zu Tile Y-Koordinate."""
    lat_rad = math.radians(lat)
    return int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * (1 << zoom))


def get_tile_bounds(bbox: Tuple[float, float, float, float], zoom: int) -> Tuple[int, int, int, int]:
    """Berechnet Tile-Grenzen für eine Bounding Box und Zoom-Level."""
    west, south, east, north = bbox

    x_min = lon_to_tile_x(west, zoom)
    x_max = lon_to_tile_x(east, zoom)
    y_min = lat_to_tile_y(north, zoom)  # Nord hat kleinere Y-Koordinate
    y_max = lat_to_tile_y(south, zoom)

    return x_min, y_min, x_max, y_max


def generate_tile_list(bbox: Tuple[float, float, float, float], zoom_min: int, zoom_max: int) -> List[Tuple[int, int, int]]:
    """Generiert Liste aller Tiles für die angegebene Bounding Box und Zoom-Levels."""
    tiles: List[Tuple[int, int, int]] = []

    for zoom in range(zoom_min, zoom_max + 1):
        x_min, y_min, x_max, y_max = get_tile_bounds(bbox, zoom)

        for x in range(x_min, x_max + 1):
            for y in range(y_min, y_max + 1):
                tiles.append((zoom, x, y))

    return tiles


def flip_y(y: int, zoom: int) -> int:
    """Konvertiert TMS Y-Koordinate (MBTiles-Standard) zu OSM Y-Koordinate."""
    return (1 << zoom) - 1 - y


def create_mbtiles_database(db_path: Path) -> sqlite3.Connection:
    """Erstellt eine neue MBTiles-Datenbank mit korrektem Schema."""
    if db_path.exists():
        db_path.unlink()

    conn = sqlite3.connect(str(db_path))
    cursor = conn.cursor()

    # Erstelle Metadata-Tabelle
    cursor.execute("""
        CREATE TABLE metadata (
            name TEXT PRIMARY KEY,
            value TEXT
        )
    """)

    # Erstelle Tiles-Tabelle
    cursor.execute("""
        CREATE TABLE tiles (
            zoom_level INTEGER,
            tile_column INTEGER,
            tile_row INTEGER,
            tile_data BLOB,
            PRIMARY KEY (zoom_level, tile_column, tile_row)
        )
    """)

    # Füge Metadaten hinzu
    metadata: dict[str, str] = {
        "name": CONFIG["region_name"],
        "type": "baselayer",
        "version": "1.0",
        "description": CONFIG["description"],
        "format": "png",
        "bounds": f"{CONFIG['bbox'][0]},{CONFIG['bbox'][1]},{CONFIG['bbox'][2]},{CONFIG['bbox'][3]}",
        "center": f"{(CONFIG['bbox'][0] + CONFIG['bbox'][2]) / 2},{(CONFIG['bbox'][1] + CONFIG['bbox'][3]) / 2},{CONFIG['zoom_min']}",
        "minzoom": str(CONFIG["zoom_min"]),
        "maxzoom": str(CONFIG["zoom_max"]),
        "attribution": CONFIG["attribution"],
    }

    for key, value in metadata.items():
        cursor.execute("INSERT INTO metadata (name, value) VALUES (?, ?)", (key, value))

    conn.commit()
    return conn


def download_tile(session: requests.Session, z: int, x: int, y: int) -> Tuple[int, int, int, bytes | None]:
    """Lädt ein einzelnes Tile herunter mit Retry-Logik."""
    url = CONFIG["tile_server"].format(z=z, x=x, y=y)

    for attempt in range(CONFIG["retry_attempts"]):
        try:
            time.sleep(CONFIG["rate_limit_delay"])  # Rate Limiting

            response = session.get(
                url,
                timeout=CONFIG["timeout"],
                headers={"User-Agent": CONFIG["user_agent"]}
            )

            if response.status_code == 200:
                return (z, x, y, response.content)
            elif response.status_code == 404:
                # Tile existiert nicht (z.B. Ozean)
                return (z, x, y, None)
            elif response.status_code == 429:
                # Rate limit erreicht
                wait_time = min(2 ** attempt * 5, 60)
                time.sleep(wait_time)
                continue
            else:
                if attempt == CONFIG["retry_attempts"] - 1:
                    print(f"\n⚠ Fehler bei Tile {z}/{x}/{y}: HTTP {response.status_code}")
                    return (z, x, y, None)

        except requests.exceptions.RequestException as e:
            if attempt == CONFIG["retry_attempts"] - 1:
                print(f"\n⚠ Fehler bei Tile {z}/{x}/{y}: {e}")
                return (z, x, y, None)
            time.sleep(2 ** attempt)

    return (z, x, y, None)


def download_and_save_tiles(tiles: List[Tuple[int, int, int]], db_conn: sqlite3.Connection):
    """Lädt alle Tiles herunter und speichert sie in der Datenbank."""
    session = requests.Session()
    cursor = db_conn.cursor()

    successful = 0
    failed = 0
    skipped = 0

    print(f"\n📥 Starte Download von {len(tiles)} Tiles mit {CONFIG['max_workers']} parallelen Verbindungen...")
    print(f"⏱️  Rate Limit: {CONFIG['rate_limit_delay']}s zwischen Requests\n")

    with ThreadPoolExecutor(max_workers=CONFIG["max_workers"]) as executor:
        # Starte Downloads
        futures = {executor.submit(download_tile, session, z, x, y): (z, x, y) for z, x, y in tiles}

        # Progress Bar
        with tqdm(total=len(tiles), desc="Download", unit="tiles") as pbar:
            for future in as_completed(futures):
                z, x, y, tile_data = future.result()

                if tile_data is not None:
                    # Konvertiere zu TMS Y-Koordinate für MBTiles
                    tms_y = flip_y(y, z)

                    # Speichere in Datenbank
                    cursor.execute(
                        "INSERT OR REPLACE INTO tiles (zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?)",
                        (z, x, tms_y, tile_data)
                    )
                    successful += 1

                    # Commit alle 100 Tiles für bessere Performance
                    if successful % 100 == 0:
                        db_conn.commit()
                else:
                    # Prüfe ob 404 (normal) oder echter Fehler
                    if tile_data is None:
                        skipped += 1

                pbar.update(1)

    # Finaler Commit
    db_conn.commit()

    print("\n✓ Download abgeschlossen:")
    print(f"  - Erfolgreich: {successful}")
    print(f"  - Übersprungen: {skipped}")
    print(f"  - Fehlgeschlagen: {failed}")


def validate_mbtiles(db_path: Path) -> bool:
    """Validiert die erstellte MBTiles-Datei."""
    if not db_path.exists():
        print("✗ Datei existiert nicht für Validierung")
        return False

    try:
        conn = sqlite3.connect(str(db_path))
        cursor = conn.cursor()

        # Zähle Tiles
        cursor.execute("SELECT COUNT(*) FROM tiles")
        tile_count = cursor.fetchone()[0]

        # Hole Metadaten
        cursor.execute("SELECT name, value FROM metadata")
        metadata = dict(cursor.fetchall())

        print("\n--- MBTiles Validierung ---")
        print(f"✓ Anzahl Tiles: {tile_count:,}")
        print(f"✓ Region: {metadata.get('name', 'N/A')}")
        print(f"✓ Zoom-Levels: {metadata.get('minzoom', 'N/A')} - {metadata.get('maxzoom', 'N/A')}")
        print(f"✓ Format: {metadata.get('format', 'N/A')}")

        conn.close()
        return True

    except Exception as e:
        print(f"✗ Validierung fehlgeschlagen: {e}")
        return False


def main():
    """Hauptfunktion."""
    print("🗺️  OSM Tile-Download Script für Hessen")
    print("=" * 60)

    # Generiere Tile-Liste
    print("\n📊 Berechne benötigte Tiles...")
    tiles = generate_tile_list(
        CONFIG["bbox"],
        CONFIG["zoom_min"],
        CONFIG["zoom_max"]
    )

    print(f"\n{'='*60}")
    print(f"Region: {CONFIG['region_name']}")
    print(f"Bounding Box: {CONFIG['bbox']}")
    print(f"Zoom-Levels: {CONFIG['zoom_min']}-{CONFIG['zoom_max']}")
    print(f"Anzahl Tiles gesamt: {len(tiles):,}")
    print(f"Output: {CONFIG['output_file']}")
    print(f"{'='*60}")

    # Schätze Downloadzeit
    estimated_time = len(tiles) * CONFIG["rate_limit_delay"] / CONFIG["max_workers"] / 60
    print(f"\n⏱️  Geschätzte Downloadzeit: {estimated_time:.1f} Minuten")
    print("⚠️  Bitte beachten: OSM Tile Usage Policy!")
    print("   - Nicht mehr als 2 parallele Verbindungen")
    print("   - Rate Limiting wird respektiert")
    print("   - Für produktive Nutzung eigenen Tile-Server verwenden!\n")

    # Erstelle MBTiles-Datenbank
    output_path = Path(CONFIG["output_file"])
    db_conn = create_mbtiles_database(output_path)

    try:
        # Lade Tiles herunter
        download_and_save_tiles(tiles, db_conn)

    finally:
        db_conn.close()

    # Validiere Ergebnis
    if validate_mbtiles(output_path):
        file_size_mb = output_path.stat().st_size / (1024 * 1024)
        print(f"\n{'='*60}")
        print(f"✓ Dateigröße: {file_size_mb:.2f} MB")
        print(f"✓ Datei bereit: {output_path}")
        print(f"{'='*60}")
        print("\n✅ Alles erfolgreich abgeschlossen!")
        return 0
    else:
        print("\n✗ Validierung fehlgeschlagen!")
        return 1


if __name__ == "__main__":
    sys.exit(main())
