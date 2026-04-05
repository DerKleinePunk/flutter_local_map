#!/usr/bin/env python3
"""
Extract searchable place names from MBTiles vector tiles.

The MBTiles tile_data blobs are gzip-compressed Mapbox Vector Tiles (protobuf).
This script decompresses each blob, decodes the MVT protobuf, and extracts
known name fields from relevant layers into a SQLite FTS5 index.

Usage:
  python extract_names_to_sqlite.py <input.mbtiles> <output.db>
"""

import gzip
import math
import sqlite3
import sys
import zlib
from pathlib import Path

try:
    import mapbox_vector_tile
except ImportError:
    print("[error] mapbox-vector-tile ist nicht installiert.")
    print("        Installiere es mit: pip install mapbox-vector-tile")
    sys.exit(1)

try:
    from tqdm import tqdm
except ImportError:
    def tqdm(iterable, *args, **kwargs):
        return iterable


LAYER_PRIORITY = [
    "place",
    "poi",
    "mountain_peak",
    "water_name",
    "transportation_name",
]

NAME_FIELDS = [
    "name",
    "name:de",
    "name:en",
    "name:latin",
]


def tile_pixel_to_lonlat(tile_x, tile_y, zoom, extent, pixel_x, pixel_y):
    """Convert MVT tile-local coordinates into WGS84 lon/lat."""
    world_tiles = 2.0 ** zoom
    normalized_x = (tile_x + (pixel_x / extent)) / world_tiles
    normalized_y = (tile_y + (pixel_y / extent)) / world_tiles
    lon = normalized_x * 360.0 - 180.0
    mercator_y = math.pi * (1 - 2 * normalized_y)
    lat = math.degrees(math.atan(math.sinh(mercator_y)))
    return lon, lat


def build_transformer(tile_x, tile_y, zoom, extent):
    def transformer(pixel_x, pixel_y):
        return tile_pixel_to_lonlat(tile_x, tile_y, zoom, extent, pixel_x, pixel_y)

    return transformer


def flatten_points(coordinates):
    if not coordinates:
        return []

    if isinstance(coordinates[0], (int, float)):
        return [coordinates]

    flattened = []
    for item in coordinates:
        flattened.extend(flatten_points(item))
    return flattened


def geometry_to_latlng(geometry):
    geometry_type = geometry.get("type")
    coordinates = geometry.get("coordinates")
    points = flatten_points(coordinates)
    if not points:
        return None

    if geometry_type == "Point":
        lon, lat = coordinates
        return lat, lon

    if geometry_type == "MultiPoint":
        lon = sum(point[0] for point in points) / len(points)
        lat = sum(point[1] for point in points) / len(points)
        return lat, lon

    if geometry_type in {"LineString", "MultiLineString", "Polygon", "MultiPolygon"}:
        lon = sum(point[0] for point in points) / len(points)
        lat = sum(point[1] for point in points) / len(points)
        return lat, lon

    return None


def maybe_decompress_tile(blob):
    """MBTiles usually store MVT blobs gzip-compressed; fall back gracefully."""
    if blob.startswith(b"\x1f\x8b"):
        return gzip.decompress(blob)

    try:
        return zlib.decompress(blob)
    except zlib.error:
        return blob


def choose_name(properties):
    for field_name in NAME_FIELDS:
        value = properties.get(field_name)
        if isinstance(value, str):
            value = value.strip()
            if value:
                return value, field_name
    return None, None


def choose_detail(properties):
    for field_name in ("class", "subclass", "ref"):
        value = properties.get(field_name)
        if value is None:
            continue
        value = str(value).strip()
        if value:
            return value
    return None


def extract_names_from_mbtiles(mbtiles_path, output_db_path):
    input_conn = sqlite3.connect(mbtiles_path)
    input_conn.row_factory = sqlite3.Row
    input_cursor = input_conn.cursor()

    output_conn = sqlite3.connect(output_db_path)
    output_cursor = output_conn.cursor()

    output_cursor.execute("DROP TABLE IF EXISTS names")
    output_cursor.execute("DROP TABLE IF EXISTS names_meta")

    output_cursor.execute(
        """
        CREATE VIRTUAL TABLE names USING fts5(
            id UNINDEXED,
            name,
            lat UNINDEXED,
            lng UNINDEXED,
            zoom UNINDEXED,
            type UNINDEXED,
            detail,
            source_field UNINDEXED
        )
        """
    )
    output_cursor.execute(
        """
        CREATE TABLE names_meta (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            lat REAL NOT NULL,
            lng REAL NOT NULL,
            zoom INTEGER NOT NULL,
            type TEXT NOT NULL,
            detail TEXT,
            source_field TEXT NOT NULL,
            UNIQUE(name, type)
        )
        """
    )

    total_tiles = input_cursor.execute(
        "SELECT COUNT(*) AS count FROM tiles"
    ).fetchone()["count"]
    print(f"[info] Found {total_tiles} tiles in {mbtiles_path}")

    rows = input_cursor.execute(
        """
        SELECT zoom_level, tile_column, tile_row, tile_data
        FROM tiles
        ORDER BY zoom_level DESC, tile_column, tile_row
        """
    ).fetchall()

    entries = []
    seen = set()
    decode_failures = 0

    for row in tqdm(rows, total=total_tiles, desc="Decode MVT"):
        zoom = row["zoom_level"]
        tile_x = row["tile_column"]
        tile_y_tms = row["tile_row"]
        tile_y = ((2 ** zoom) - 1) - tile_y_tms
        blob = bytes(row["tile_data"])

        decompressed_blob = maybe_decompress_tile(blob)

        try:
            probe_tile = mapbox_vector_tile.decode(
                decompressed_blob,
                default_options={"geojson": False, "y_coord_down": True},
            )
        except Exception:
            decode_failures += 1
            continue

        for layer_name in LAYER_PRIORITY:
            layer = probe_tile.get(layer_name)
            if not layer:
                continue

            extent = layer.get("extent", 4096)
            decoded_tile = mapbox_vector_tile.decode(
                decompressed_blob,
                per_layer_options={
                    layer_name: {
                        "transformer": build_transformer(tile_x, tile_y, zoom, extent),
                        "y_coord_down": True,
                    }
                },
            )
            transformed_layer = decoded_tile.get(layer_name)
            if not transformed_layer:
                continue

            for feature in transformed_layer.get("features", []):
                properties = feature.get("properties", {})
                name, source_field = choose_name(properties)
                if not name:
                    continue

                key = (name.casefold(), layer_name)
                if key in seen:
                    continue
                seen.add(key)

                representative_point = geometry_to_latlng(feature.get("geometry", {}))
                if representative_point is None:
                    continue

                lat, lng = representative_point
                entries.append(
                    {
                        "name": name,
                        "lat": lat,
                        "lng": lng,
                        "zoom": zoom,
                        "type": layer_name,
                        "detail": choose_detail(properties),
                        "source_field": source_field,
                    }
                )

    print(f"[info] Decode failures: {decode_failures}")
    print(f"[info] Extracted {len(entries)} unique names")

    for index, entry in enumerate(tqdm(entries, desc="Write DB"), start=1):
        row = (
            index,
            entry["name"],
            entry["lat"],
            entry["lng"],
            entry["zoom"],
            entry["type"],
            entry["detail"],
            entry["source_field"],
        )
        output_cursor.execute(
            """
            INSERT INTO names_meta (id, name, lat, lng, zoom, type, detail, source_field)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            row,
        )
        output_cursor.execute(
            """
            INSERT INTO names (id, name, lat, lng, zoom, type, detail, source_field)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            row,
        )

    output_conn.commit()
    final_count = output_cursor.execute(
        "SELECT COUNT(*) FROM names_meta"
    ).fetchone()[0]
    print(f"[ok] Created {output_db_path} with {final_count} searchable names")

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

    output_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        extract_names_from_mbtiles(str(input_path), str(output_path))
    except Exception as error:
        print(f"[error] Failed to extract names: {error}")
        sys.exit(1)
