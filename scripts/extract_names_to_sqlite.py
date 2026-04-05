#!/usr/bin/env python3
"""
Extract place names from MBTiles vector tiles.
Strict filtering to find actual location names, not metadata.

Usage:
  python extract_names_to_sqlite.py <input.mbtiles> <output.db>
"""

import sqlite3
import sys
import math
from pathlib import Path

try:
    from tqdm import tqdm
except ImportError:
    def tqdm(iterable, *args, **kwargs):
        return iterable


def extract_strings_raw(data):
    """Extract UTF-8 strings from binary tile data."""
    strings = []
    current = bytearray()
    
    for byte in data:
        # Keep printable ASCII and UTF-8 continuation bytes
        if (32 <= byte < 127) or byte >= 128:
            current.append(byte)
        else:
            if len(current) >= 4:  # Minimum 4 chars
                try:
                    text = bytes(current).decode('utf-8', errors='ignore').strip()
                    if len(text) >= 4:
                        strings.append(text)
                except:
                    pass
            current = bytearray()
    
    # Don't forget last string
    if len(current) >= 4:
        try:
            text = bytes(current).decode('utf-8', errors='ignore').strip()
            if len(text) >= 4:
                strings.append(text)
        except:
            pass
    
    return strings


def is_location_name(text):
    """Very strict filter for actual location names."""
    # Length: 4-50 chars (city names, towns, regions, landmarks)
    if len(text) < 4 or len(text) > 50:
        return False
    
    # Must start with uppercase letter
    if not text[0].isupper():
        return False
    
    # Only allow Latin letters, spaces, hyphens, apostrophes, periods
    allowed = set('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz- \'.')
    if not all(c in allowed for c in text):
        return False
    
    # Must have at least 2 letters (to avoid "St.", "Dr.", etc)
    letter_count = sum(1 for c in text if c.isalpha())
    if letter_count < 2:
        return False
    
    # Skip common metadata words
    skip = {
        'layer', 'class', 'type', 'name', 'feature', 'source', 'id',
        'field', 'data', 'style', 'null', 'import', 'export',
        'object', 'array', 'value', 'error', 'debug', 'key'
    }
    if text.lower() in skip:
        return False
    
    # Skip all-caps strings longer than 4 chars (likely acronyms/metadata)
    if len(text) > 4 and text.isupper():
        return False
    
    # Don't start with period, hyphen, or apostrophe
    if text[0] in '.!?,;:-':
        return False
    
    return True


def web_mercator_to_latlng(x, y, z):
    """Convert Web Mercator tile coordinates to lat/lng."""
    n = 2.0 ** z
    lng = (x / n) * 360.0 - 180.0
    y_mercator = (y / n) * 2.0 * math.pi - math.pi
    lat = math.degrees(2.0 * math.atan(math.exp(y_mercator)) - math.pi / 2.0)
    return lat, lng


def extract_names_from_mbtiles(mbtiles_path, output_db_path):
    """Extract location names from vector tiles."""
    
    input_conn = sqlite3.connect(mbtiles_path)
    input_cursor = input_conn.cursor()
    
    input_cursor.execute("SELECT COUNT(*) as count FROM tiles")
    total_tiles = input_cursor.fetchone()[0]
    print(f"[info] Found {total_tiles} tiles")
    
    output_conn = sqlite3.connect(output_db_path)
    output_cursor = output_conn.cursor()
    
    output_cursor.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS names USING fts5(
            id UNINDEXED, name, lat UNINDEXED, lng UNINDEXED, zoom UNINDEXED
        )
    """)
    output_cursor.execute("""
        CREATE TABLE IF NOT EXISTS names_meta (
            id INTEGER PRIMARY KEY, name TEXT UNIQUE, lat REAL, lng REAL, zoom INT
        )
    """)
    
    input_cursor.execute("""
        SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles 
        ORDER BY zoom_level DESC
    """)
    
    names_data = []
    seen = set()
    idx = 0
    
    for row in tqdm(input_cursor.fetchall(), total=total_tiles, desc="Extract"):
        z, x, y, tile_data = row
        try:
            strings = extract_strings_raw(bytes(tile_data))
            for text in strings:
                if not is_location_name(text):
                    continue
                text_key = text.lower()
                if text_key in seen:
                    continue
                seen.add(text_key)
                lat, lng = web_mercator_to_latlng(x, y, z)
                idx += 1
                names_data.append((idx, text, lat, lng, z))
        except:
            pass
    
    print(f"[info] Found {len(names_data)} names")
    
    for idx, name, lat, lng, z in tqdm(names_data, desc="Write"):
        try:
            output_cursor.execute("INSERT INTO names_meta VALUES (?,?,?,?,?)", (idx, name, lat, lng, z))
            output_cursor.execute("INSERT INTO names VALUES (?,?,?,?,?)", (idx, name, lat, lng, z))
        except:
            pass
    
    output_conn.commit()
    output_cursor.execute("SELECT COUNT(*) FROM names_meta")
    count = output_cursor.fetchone()[0]
    print(f"[ok] Created DB with {count} names")
    
    input_conn.close()
    output_conn.close()


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    
    inp = Path(sys.argv[1])
    out = Path(sys.argv[2])
    
    if not inp.exists():
        print(f"[error] Not found: {inp}")
        sys.exit(1)
    
    out.parent.mkdir(parents=True, exist_ok=True)
    
    try:
        extract_names_from_mbtiles(str(inp), str(out))
    except Exception as e:
        print(f"[error] {e}")
        sys.exit(1)
