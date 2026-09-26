#!/usr/bin/env python3
"""
Extract searchable place names from MBTiles vector tiles.

The MBTiles tile_data blobs are gzip-compressed Mapbox Vector Tiles (protobuf).
This script decompresses each blob, decodes the MVT protobuf, and extracts
known name fields from relevant layers into a SQLite FTS5 index.

Alongside the search index it writes tables for reverse lookup (position ->
place and street name), see REVERSE_* below.

Usage:
  python extract_names_to_sqlite.py <input.mbtiles> <output.db> [--max-zoom N]

Options:
  --max-zoom N  Maximum zoom level to process (default: 14).
                Tiles at z15+ repeat the same names and are skipped
                by default. Use --max-zoom 17 to process all tiles.
"""

import gzip
import math
import sqlite3
import sys
import time
import zlib
import os
from concurrent.futures import ProcessPoolExecutor, as_completed
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
WORKER_BATCH_SIZE = 200  # tiles per parallel batch

# Reverse lookup: which place and street is at a position.
#
# The search index keeps every name only once per layer, so it knows a single
# "Hauptstrasse" for the whole country - useless for "where am I". The reverse
# tables keep every occurrence instead:
#   reverse_names    (id, name, type, detail)   - one row per distinct name
#   reverse_places   (name_id, lat_e5, lng_e5)   - place nodes (towns, villages)
#   reverse_streets  (name_id, lat_e5, lng_e5)   - points along named streets
# Coordinates are degrees * 1e5 as INTEGER (~1 m), which SQLite stores in a
# few bytes instead of eight. A plain B-tree index on (lat_e5, lng_e5) is
# enough for the small boxes the app asks for, and needs no R*Tree module.
#
# Streets come only from z14 tiles: there every named street is present with
# its full geometry, and one z14 tile is small enough (~1.6 km) that points on
# the line are exact. A point every REVERSE_STREET_SPACING_M metres keeps the
# error along the street below half that distance.
REVERSE_STREET_ZOOM = 14
REVERSE_STREET_SPACING_M = 100
# Duplicates (the same street from a neighbouring tile's buffer, the same
# place node on every zoom level) are dropped per grid cell, in 1e-5 degrees.
REVERSE_STREET_CELL_E5 = 50  # ~55 m
REVERSE_PLACE_CELL_E5 = 200  # ~220 m

EARTH_RADIUS_M = 6371000.0

# Tiles above this zoom level are skipped during extraction.
# All place names, POIs, water names and major roads are already
# fully indexed at z14; higher zooms only repeat them.
MAX_EXTRACTION_ZOOM = 14


def format_duration(seconds):
    total_seconds = max(0, int(round(seconds)))
    hours, remainder = divmod(total_seconds, 3600)
    minutes, secs = divmod(remainder, 60)

    parts = []
    if hours:
        parts.append(f"{hours}h")
    if hours or minutes:
        parts.append(f"{minutes}m")
    parts.append(f"{secs}s")
    return " ".join(parts)


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

    if geometry_type == "LineString":
        # A vertex in the middle of the line, so the point lies on the street
        # itself - the centroid of a winding road can be far off it.
        return tuple(points[len(points) // 2])

    if geometry_type == "MultiLineString":
        longest = max(coordinates, key=len)
        return tuple(longest[len(longest) // 2])

    if geometry_type in {"Polygon", "MultiPolygon"}:
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


def line_parts(geometry):
    """The coordinate lists of a (Multi)LineString, empty for anything else."""
    geometry_type = geometry.get("type")
    coordinates = geometry.get("coordinates") or []
    if geometry_type == "LineString":
        return [coordinates]
    if geometry_type == "MultiLineString":
        return coordinates
    return []


def sample_line(part, transform, extent, spacing_m):
    """Points every spacing_m metres along one line, inside the tile only.

    Parts in the tile buffer belong to the neighbouring tile, which samples
    them itself.
    """
    samples = []
    previous = None
    carried = 0.0
    for pixel_x, pixel_y in part:
        lon, lat = transform(pixel_x, pixel_y)
        inside = 0 <= pixel_x <= extent and 0 <= pixel_y <= extent
        if previous is None:
            if inside:
                samples.append((lat, lon))
            previous = (lat, lon, inside)
            continue
        prev_lat, prev_lon, prev_inside = previous
        dlat = math.radians(lat - prev_lat)
        dlon = math.radians(lon - prev_lon) * math.cos(math.radians(lat))
        length = EARTH_RADIUS_M * math.hypot(dlat, dlon)
        position = spacing_m - carried
        while position <= length:
            f = position / length
            if prev_inside or inside:
                samples.append(
                    (prev_lat + (lat - prev_lat) * f, prev_lon + (lon - prev_lon) * f)
                )
            position += spacing_m
        carried = length - (position - spacing_m)
        previous = (lat, lon, inside)
    # The end point, so short streets between two samples are not lost.
    if previous is not None and previous[2]:
        samples.append((previous[0], previous[1]))
    return samples


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


def _decode_tile(args):
    """Worker: decode one MVT tile blob and return all extracted name records.

    Returns (decode_error: bool, records: list[tuple], reverse: list[tuple]).
    Each record is (name, lat, lng, zoom, layer_name, detail, source_field).
    Each reverse entry is (kind, name, detail, lat, lng) with kind "place" or
    "street".
    """
    zoom, tile_x, tile_y_tms, blob = args
    tile_y = ((2 ** zoom) - 1) - tile_y_tms
    decompressed = maybe_decompress_tile(blob)

    try:
        decoded_tile = mapbox_vector_tile.decode(
            decompressed, default_options={"geojson": False, "y_coord_down": True}
        )
    except Exception:
        return True, [], []

    records = []
    reverse = []
    for layer_name in LAYER_PRIORITY:
        layer = decoded_tile.get(layer_name)
        if not layer:
            continue
        extent = layer.get("extent", 4096)
        for feature in layer.get("features", []):
            props = feature.get("properties", {})
            name, source_field = choose_name(props)
            if not name:
                continue
            rp = geometry_to_latlng(
                feature.get("geometry", {}), tile_x, tile_y, zoom, extent
            )
            if rp is None:
                continue
            lat, lng = rp
            detail = choose_detail(props)
            records.append(
                (name, lat, lng, zoom, layer_name, detail, source_field)
            )
            if layer_name == "place" and feature.get("geometry", {}).get("type") == "Point":
                reverse.append(("place", name, detail, lat, lng))

    # Streets for the reverse lookup. Autobahnen often carry only a ref
    # ("A 5"), which is what a driver wants to see anyway.
    streets = decoded_tile.get("transportation_name") if zoom == REVERSE_STREET_ZOOM else None
    if streets:
        extent = streets.get("extent", 4096)
        transform = build_transformer(tile_x, tile_y, zoom, extent)
        for feature in streets.get("features", []):
            props = feature.get("properties", {})
            name, _ = choose_name(props)
            if not name:
                ref = props.get("ref")
                name = str(ref).strip() if ref is not None else None
            if not name:
                continue
            detail = props.get("class")
            detail = str(detail) if detail is not None else None
            for part in line_parts(feature.get("geometry", {})):
                for lat, lng in sample_line(part, transform, extent, REVERSE_STREET_SPACING_M):
                    reverse.append(("street", name, detail, lat, lng))
    return False, records, reverse


def extract_names_from_mbtiles(mbtiles_path, output_db_path, max_zoom=MAX_EXTRACTION_ZOOM):
    return _extract(mbtiles_path, output_db_path, max_zoom=max_zoom, workers=None)


def _extract(mbtiles_path, output_db_path, max_zoom=MAX_EXTRACTION_ZOOM, workers=None):
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
    output_cursor.execute("DROP TABLE IF EXISTS reverse_names")
    output_cursor.execute("DROP TABLE IF EXISTS reverse_places")
    output_cursor.execute("DROP TABLE IF EXISTS reverse_streets")

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
    output_cursor.execute(
        """
        CREATE TABLE reverse_names (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            detail TEXT
        )
        """
    )
    for table in ("reverse_places", "reverse_streets"):
        output_cursor.execute(
            f"""
            CREATE TABLE {table} (
                name_id INTEGER NOT NULL,
                lat_e5 INTEGER NOT NULL,
                lng_e5 INTEGER NOT NULL
            )
            """
        )

    total_tiles = input_cursor.execute(
        "SELECT COUNT(*) AS count FROM tiles WHERE zoom_level <= ?",
        (max_zoom,),
    ).fetchone()["count"]
    total_tiles_all = input_cursor.execute(
        "SELECT COUNT(*) AS count FROM tiles"
    ).fetchone()["count"]
    print(f"[info] Found {total_tiles_all} tiles in {mbtiles_path}")
    print(f"[info] Processing {total_tiles} tiles at zoom <={max_zoom} (skipping {total_tiles_all - total_tiles} high-zoom tiles)")

    seen = set()
    decode_failures = 0
    skipped_geometries = 0
    inserted_rows = 0
    next_id = 1

    pending_rows = []

    reverse_name_ids = {}
    reverse_seen = set()
    pending_reverse_names = []
    pending_reverse_points = {"place": [], "street": []}
    reverse_counts = {"place": 0, "street": 0}

    def add_reverse(kind, name, detail, lat, lng):
        key = (name, kind, detail)
        name_id = reverse_name_ids.get(key)
        if name_id is None:
            name_id = len(reverse_name_ids) + 1
            reverse_name_ids[key] = name_id
            pending_reverse_names.append((name_id, name, kind, detail))
        lat_e5 = round(lat * 1e5)
        lng_e5 = round(lng * 1e5)
        cell = REVERSE_STREET_CELL_E5 if kind == "street" else REVERSE_PLACE_CELL_E5
        cell_key = (name_id, lat_e5 // cell, lng_e5 // cell)
        if cell_key in reverse_seen:
            return
        reverse_seen.add(cell_key)
        pending_reverse_points[kind].append((name_id, lat_e5, lng_e5))

    def flush_reverse_rows():
        nonlocal pending_reverse_names
        if pending_reverse_names:
            output_cursor.executemany(
                "INSERT INTO reverse_names (id, name, type, detail) VALUES (?, ?, ?, ?)",
                pending_reverse_names,
            )
            pending_reverse_names = []
        for kind, table in (("place", "reverse_places"), ("street", "reverse_streets")):
            rows = pending_reverse_points[kind]
            if rows:
                output_cursor.executemany(
                    f"INSERT INTO {table} (name_id, lat_e5, lng_e5) VALUES (?, ?, ?)",
                    rows,
                )
                reverse_counts[kind] += len(rows)
                pending_reverse_points[kind] = []
        output_conn.commit()

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

    num_workers = workers or max(1, (os.cpu_count() or 4) - 1)
    print(f"[info] Using {num_workers} worker process(es) for parallel decode")

    def _iter_tile_args():
        for row in input_cursor.execute(
            """
            SELECT zoom_level, tile_column, tile_row, tile_data
            FROM tiles
            WHERE zoom_level <= ?
            """,
            (max_zoom,),
        ):
            yield (
                row["zoom_level"],
                row["tile_column"],
                row["tile_row"],
                bytes(row["tile_data"]),
            )

    tile_iter = _iter_tile_args()
    exhausted = False

    with ProcessPoolExecutor(max_workers=num_workers) as executor:
        while not exhausted:
            # Fill one batch of args without loading all tiles at once.
            batch_args = []
            for _ in range(WORKER_BATCH_SIZE * num_workers):
                item = next(tile_iter, None)
                if item is None:
                    exhausted = True
                    break
                batch_args.append(item)

            if not batch_args:
                break

            futures = [executor.submit(_decode_tile, arg) for arg in batch_args]
            for future in as_completed(futures):
                decode_error, records, reverse = future.result()
                processed_tiles += 1
                if decode_error:
                    decode_failures += 1
                else:
                    for name, lat, lng, zoom, layer_name, detail, source_field in records:
                        key = (name.casefold(), layer_name)
                        if key in seen:
                            continue
                        seen.add(key)
                        pending_rows.append(
                            (next_id, name, lat, lng, zoom, layer_name, detail, source_field)
                        )
                        next_id += 1
                    for kind, name, detail, lat, lng in reverse:
                        add_reverse(kind, name, detail, lat, lng)

            if len(pending_rows) >= BATCH_SIZE:
                flush_pending_rows()
            if (
                len(pending_reverse_points["street"]) + len(pending_reverse_points["place"])
                >= BATCH_SIZE * 10
            ):
                flush_reverse_rows()

            if progress is not None:
                progress.update(len(batch_args))
            elif processed_tiles % 5000 == 0:
                print(
                    f"[info] Processed {processed_tiles}/{total_tiles} tiles "
                    f"(decode failures: {decode_failures}, written rows: {inserted_rows})"
                )

    flush_pending_rows()
    flush_reverse_rows()

    # Indexes after the bulk insert - building them once is much faster than
    # keeping them up to date row by row.
    print("[info] Building reverse lookup indexes")
    output_cursor.execute(
        "CREATE INDEX reverse_places_pos ON reverse_places (lat_e5, lng_e5)"
    )
    output_cursor.execute(
        "CREATE INDEX reverse_streets_pos ON reverse_streets (lat_e5, lng_e5)"
    )
    output_conn.commit()

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
    print(
        f"[info] Reverse lookup: {len(reverse_name_ids)} names, "
        f"{reverse_counts['place']} place points, {reverse_counts['street']} street points"
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

    args = sys.argv[1:]
    max_zoom = MAX_EXTRACTION_ZOOM

    # Parse optional --max-zoom N
    if "--max-zoom" in args:
        idx = args.index("--max-zoom")
        if idx + 1 >= len(args):
            print("[error] --max-zoom requires a value")
            sys.exit(1)
        try:
            max_zoom = int(args[idx + 1])
        except ValueError:
            print(f"[error] Invalid --max-zoom value: {args[idx + 1]}")
            sys.exit(1)
        args = args[:idx] + args[idx + 2:]

    if len(args) < 2:
        print(__doc__)
        sys.exit(1)

    input_path = Path(args[0])
    output_path = Path(args[1])

    if not input_path.exists():
        print(f"[error] Input file not found: {input_path}")
        sys.exit(1)

    output_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"[info] Max zoom: {max_zoom}")
    started_at = time.perf_counter()
    try:
        _extract(str(input_path), str(output_path), max_zoom=max_zoom)
        elapsed = time.perf_counter() - started_at
        print(f"[ok] Total runtime: {format_duration(elapsed)}")
    except Exception as error:
        elapsed = time.perf_counter() - started_at
        print(f"[info] Runtime before failure: {format_duration(elapsed)}")
        print(f"[error] Failed to extract names: {error}")
        sys.exit(1)
