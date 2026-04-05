#!/usr/bin/env python3
"""
Extract place names, POI, and mountain peaks from MBTiles vector tiles
and create a searchable SQLite database with FTS5 full-text search.

Usage:
  python extract_names_to_sqlite.py <input.mbtiles> <output.db>

Example:
  python extract_names_to_sqlite.py map/tiles-germany/vogelsberg.mbtiles map/vogelsberg_names.db
"""

import sqlite3
import sys
import math
from pathlib import Path

try:
    import mapbox_vector_tile
except ImportError:
    print("[error] mapbox-vector-tile not installed. Install with:")
    print("  pip install mapbox-vector-tile")
    sys.exit(1)

try:
    from tqdm import tqdm
except ImportError:
    # Fallback if tqdm not available
    def tqdm(iterable, *args, **kwargs):
        return iterable


def web_mercator_to_latlng(x, y, z):
    """
    Convert Web Mercator tile coordinates to lat/lng.
    x, y are in tile coordinates (0 to 2^z-1)
    Returns (lat, lng)
    """
    n = 2.0 ** z
    lng = (x / n) * 360.0 - 180.0

    # Convert y to lat
    y_mercator = (y / n) * 2.0 * math.pi - math.pi
    lat = math.degrees(2.0 * math.atan(math.exp(y_mercator)) - math.pi / 2.0)

    return lat, lng


def extract_names_from_mbtiles(mbtiles_path, output_db_path):
    """
    Extract names from vector tile layers and create FTS5 searchable database.
    """

    # Layers to extract names from
    LAYERS_TO_EXTRACT = ["place", "poi", "mountain_peak"]

    # Open input MBTiles
    input_conn = sqlite3.connect(mbtiles_path)
    input_conn.row_factory = sqlite3.Row
    input_cursor = input_conn.cursor()

    # Get tile count for progress bar
    input_cursor.execute("SELECT COUNT(*) as count FROM tiles")
    total_tiles = input_cursor.fetchone()["count"]
    print(f"[info] Found {total_tiles} tiles in {mbtiles_path}")

    # Create output database with FTS5
    output_conn = sqlite3.connect(output_db_path)
    output_cursor = output_conn.cursor()

    # Create FTS5 virtual table
    output_cursor.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS names USING fts5(
            id UNINDEXED,
            name,
            lat UNINDEXED,
            lng UNINDEXED,
            zoom UNINDEXED,
            type UNINDEXED,
            detail
        )
    """)

    # Create regular index table for metadata
    output_cursor.execute("""
        CREATE TABLE IF NOT EXISTS names_meta (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            lat REAL NOT NULL,
            lng REAL NOT NULL,
            zoom INTEGER NOT NULL,
            type TEXT NOT NULL,
            detail TEXT
        )
    """)

    # Extract names from tiles
    input_cursor.execute("SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles ORDER BY zoom_level DESC, tile_column, tile_row")

    names_data = []
    seen_names = set()

    for row in tqdm(input_cursor.fetchall(), total=total_tiles, desc="Extracting names"):
        z = row["zoom_level"]
        x = row["tile_column"]
        y = row["tile_row"]
        tile_data = row["tile_data"]

        try:
            # Decode vector tile
            tile = mapbox_vector_tile.decode(tile_data)

            # Process each relevant layer
            for layer_name in LAYERS_TO_EXTRACT:
                if layer_name not in tile:
                    continue

                layer = tile[layer_name]

                for feature in layer["features"]:
                    properties = feature.get("properties", {})
                    geom = feature.get("geometry", [])

                    # Get name (prefer name:en, then name, then name:de)
                    name = properties.get("name:en") or properties.get("name") or properties.get("name:de")

                    if not name or not isinstance(name, str) or not name.strip():
                        continue

                    name = name.strip()

                    # Skip duplicates (same name in same layer)
                    name_key = (name, layer_name)
                    if name_key in seen_names:
                        continue
                    seen_names.add(name_key)

                    # Get geometry center
                    if not geom:
                        continue

                    # Calculate tile center in Web Mercator
                    lat, lng = web_mercator_to_latlng(x, y, z)

                    # Store detail info
                    detail = properties.get("class", "") or properties.get("type", "") or ""

                    names_data.append({
                        "name": name,
                        "lat": lat,
                        "lng": lng,
                        "zoom": z,
                        "type": layer_name,
                        "detail": detail
                    })

        except Exception as e:
            print(f"[warning] Error decoding tile z{z}/x{x}/y{y}: {e}")
            continue

    print(f"[info] Extracted {len(names_data)} unique names")

    # Insert data into both tables
    for idx, entry in enumerate(tqdm(names_data, desc="Writing to database"), 1):
        output_cursor.execute("""
            INSERT INTO names_meta (id, name, lat, lng, zoom, type, detail)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, (idx, entry["name"], entry["lat"], entry["lng"], entry["zoom"], entry["type"], entry["detail"]))

        output_cursor.execute("""
            INSERT INTO names (id, name, lat, lng, zoom, type, detail)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, (idx, entry["name"], entry["lat"], entry["lng"], entry["zoom"], entry["type"], entry["detail"]))

    # Create index on names_meta for fast lookups
    output_cursor.execute("""
        CREATE INDEX IF NOT EXISTS idx_names_meta_type_zoom
        ON names_meta(type, zoom)
    """)

    output_conn.commit()

    # Verify
    output_cursor.execute("SELECT COUNT(*) as count FROM names_meta")
    final_count = output_cursor.fetchone()[0]
    print(f"[ok] Created {output_db_path} with {final_count} searchable names")

    # Close connections
    input_conn.close()
    output_conn.close()


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    input_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])

    if not input_path.exists():
        print(f"[error] Input file not found: {input_path}")
        sys.exit(1)

    # Create output directory if needed
    output_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        extract_names_from_mbtiles(str(input_path), str(output_path))
    except Exception as e:
        print(f"[error] Failed to extract names: {e}")
        sys.exit(1)
