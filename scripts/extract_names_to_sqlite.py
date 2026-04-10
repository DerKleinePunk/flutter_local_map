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
    from tqdm import tqdm as tqdm_cls
except ImportError:
    tqdm_cls = None


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

BATCH_SIZE = 2000


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


def representative_tile_point(geometry):
    geometry_type = geometry.get("type")
    coordinates = geometry.get("coordinates")
    points = flatten_points(coordinates)
    if not points:
        return None

    if geometry_type == "Point":
        x, y = coordinates
        return x, y

    if geometry_type == "MultiPoint":
        x = sum(point[0] for point in points) / len(points)
        y = sum(point[1] for point in points) / len(points)
        return x, y

    if geometry_type in {"LineString", "MultiLineString", "Polygon", "MultiPolygon"}:
        x = sum(point[0] for point in points) / len(points)
        y = sum(point[1] for point in points) / len(points)
        return x, y

    return None


def geometry_to_latlng(geometry, tile_x, tile_y, zoom, extent):
    point = representative_tile_point(geometry)
    if point is None:
        return None

    point_x, point_y = point
    lon, lat = tile_pixel_to_lonlat(tile_x, tile_y, zoom, extent, point_x, point_y)
    return lat, lon


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
    input_conn.execute("PRAGMA temp_store = MEMORY")
    input_cursor = input_conn.cursor()

    output_conn = sqlite3.connect(output_db_path)
    output_conn.execute("PRAGMA journal_mode = WAL")
    output_conn.execute("PRAGMA synchronous = NORMAL")
    output_conn.execute("PRAGMA temp_store = MEMORY")
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

    seen = set()
    decode_failures = 0
    skipped_geometries = 0
    inserted_rows = 0
    next_id = 1

    pending_rows = []

    def flush_pending_rows():
        nonlocal inserted_rows, pending_rows
        if not pending_rows:
            return

        output_cursor.executemany(
            """
            INSERT INTO names_meta (id, name, lat, lng, zoom, type, detail, source_field)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            pending_rows,
        )
        output_cursor.executemany(
            """
            INSERT INTO names (id, name, lat, lng, zoom, type, detail, source_field)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            pending_rows,
        )
        inserted_rows += len(pending_rows)
        output_conn.commit()
        pending_rows = []

    progress = None
    if tqdm_cls is not None:
        progress = tqdm_cls(total=total_tiles, desc="Decode MVT", unit="tile")
    processed_tiles = 0

    tile_rows = input_cursor.execute(
        """
        SELECT zoom_level, tile_column, tile_row, tile_data
        FROM tiles
        """
    )

    for processed_tiles, row in enumerate(tile_rows, start=1):
        zoom = row["zoom_level"]
        tile_x = row["tile_column"]
        tile_y_tms = row["tile_row"]
        tile_y = ((2 ** zoom) - 1) - tile_y_tms
        blob = bytes(row["tile_data"])

        decompressed_blob = maybe_decompress_tile(blob)

        try:
            decoded_tile = mapbox_vector_tile.decode(
                decompressed_blob,
                default_options={"geojson": False, "y_coord_down": True},
            )
        except Exception:
            decode_failures += 1
            if progress is not None:
                progress.update(1)
            elif processed_tiles % 5000 == 0:
                print(
                    f"[info] Processed {processed_tiles}/{total_tiles} tiles "
                    f"(decode failures: {decode_failures}, written rows: {inserted_rows})"
                )
            continue

        for layer_name in LAYER_PRIORITY:
            layer = decoded_tile.get(layer_name)
            if not layer:
                continue

            extent = layer.get("extent", 4096)
            for feature in layer.get("features", []):
                properties = feature.get("properties", {})
                name, source_field = choose_name(properties)
                if not name:
                    continue

                key = (name.casefold(), layer_name)
                if key in seen:
                    continue
                seen.add(key)

                representative_point = geometry_to_latlng(
                    feature.get("geometry", {}),
                    tile_x,
                    tile_y,
                    zoom,
                    extent,
                )
                if representative_point is None:
                    skipped_geometries += 1
                    continue

                lat, lng = representative_point
                pending_rows.append(
                    (
                        next_id,
                        name,
                        lat,
                        lng,
                        zoom,
                        layer_name,
                        choose_detail(properties),
                        source_field,
                    )
                )
                next_id += 1

                if len(pending_rows) >= BATCH_SIZE:
                    flush_pending_rows()

        if progress is not None:
            progress.update(1)
        elif processed_tiles % 5000 == 0:
            print(
                f"[info] Processed {processed_tiles}/{total_tiles} tiles "
                f"(decode failures: {decode_failures}, written rows: {inserted_rows})"
            )

    flush_pending_rows()

    if progress is not None:
        progress.close()
    else:
        print(
            f"[info] Processed {processed_tiles}/{total_tiles} tiles "
            f"(decode failures: {decode_failures}, written rows: {inserted_rows})"
        )

    print(f"[info] Decode failures: {decode_failures}")
    print(f"[info] Skipped geometries: {skipped_geometries}")
    print(f"[info] Extracted {inserted_rows} unique names")

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
