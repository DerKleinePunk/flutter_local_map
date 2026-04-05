#!/usr/bin/env python3
"""
Rendert eine Vektor-MBTiles-Datei zu Raster-PNG-Tiles via tileserver-gl (Docker)
und speichert das Ergebnis als neue Raster-MBTiles-Datei.

Voraussetzung: Docker muss installiert und laufend sein.

Nutzung:
  python render_raster.py <input.mbtiles> [<output.mbtiles>] [--maxzoom N] [--workers N]

Beispiel (Testgebiet Vogelsberg):
  python render_raster.py vogelsberg.mbtiles vogelsberg_raster.mbtiles --maxzoom 14

Beispiel (Hessen komplett):
  python render_raster.py germany.mbtiles germany_raster.mbtiles --maxzoom 14
"""

import sys
import sqlite3
import subprocess
import time
import math
import json
import atexit
import shutil
import argparse
import os
import shlex
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    import requests
    from tqdm import tqdm
except ImportError:
    print("Fehler: pip install requests tqdm")
    sys.exit(1)

TILESERVER_PORT = 7654
TILESERVER_IMAGE = "maptiler/tileserver-gl"
#STYLE_NAME = "navigation"
STYLE_NAME = "basic-preview"

SCRIPT_DIR = Path(__file__).parent
PROJECT_ROOT = SCRIPT_DIR.parent
STYLE_SOURCE = PROJECT_ROOT / "assets" / "maps" / "style_navigation.json"
WORK_DIR = PROJECT_ROOT / "map" / "tiles-germany"
TMP_DIR = WORK_DIR / "_tileserver_tmp"

_container_id: str | None = None


def _cleanup_container() -> None:
    if _container_id:
        subprocess.run(["docker", "stop", _container_id], capture_output=True)
        shutil.rmtree(TMP_DIR, ignore_errors=True)


atexit.register(_cleanup_container)


# ---------------------------------------------------------------------------
# Tile-Koordinaten
# ---------------------------------------------------------------------------

def lon_to_tile_x(lon: float, zoom: int) -> int:
    return int((lon + 180.0) / 360.0 * (1 << zoom))


def lat_to_tile_y(lat: float, zoom: int) -> int:
    lat_rad = math.radians(lat)
    return int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * (1 << zoom))


def flip_y(y: int, zoom: int) -> int:
    """Konvertiert XYZ-Y zu TMS-Y (MBTiles-Standard)."""
    return (1 << zoom) - 1 - y


def generate_tiles(bbox_str: str, zoom_min: int, zoom_max: int) -> list[tuple[int, int, int]]:
    west, south, east, north = map(float, bbox_str.split(","))
    tiles: list[tuple[int, int, int]] = []
    for z in range(zoom_min, zoom_max + 1):
        x0 = lon_to_tile_x(west, z)
        x1 = lon_to_tile_x(east, z)
        y0 = lat_to_tile_y(north, z)
        y1 = lat_to_tile_y(south, z)
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                tiles.append((z, x, y))
    return tiles


# ---------------------------------------------------------------------------
# MBTiles-Hilfsfunktionen
# ---------------------------------------------------------------------------

def read_metadata(db_path: Path) -> dict[str, str]:
    conn = sqlite3.connect(str(db_path))
    cur = conn.cursor()
    cur.execute("SELECT name, value FROM metadata")
    meta = dict(cur.fetchall())
    conn.close()
    return meta


def create_raster_mbtiles(output_path: Path, source_meta: dict[str, str], zoom_max: int) -> sqlite3.Connection:
    if output_path.exists():
        output_path.unlink()
    conn = sqlite3.connect(str(output_path))
    cur = conn.cursor()
    cur.execute("CREATE TABLE metadata (name TEXT PRIMARY KEY, value TEXT)")
    cur.execute("""
        CREATE TABLE tiles (
            zoom_level  INTEGER,
            tile_column INTEGER,
            tile_row    INTEGER,
            tile_data   BLOB,
            PRIMARY KEY (zoom_level, tile_column, tile_row)
        )
    """)
    entries = {
        "name":        source_meta.get("name", "Raster Tiles"),
        "type":        "baselayer",
        "version":     "1.0",
        "description": source_meta.get("description", "Raster-Tiles gerendert aus Vektor-MBTiles"),
        "format":      "png",
        "bounds":      source_meta.get("bounds", ""),
        "minzoom":     source_meta.get("minzoom", "0"),
        "maxzoom":     str(zoom_max),
        "attribution": "© OpenStreetMap contributors",
    }
    for k, v in entries.items():
        cur.execute("INSERT INTO metadata VALUES (?, ?)", (k, v))
    conn.commit()
    return conn


# ---------------------------------------------------------------------------
# tileserver-gl vorbereiten und starten
# ---------------------------------------------------------------------------

def adapt_style(style_path: Path, data_key: str) -> dict:
    """Passt style_navigation.json für tileserver-gl an."""
    with open(style_path, encoding="utf-8") as f:
        style = json.load(f)

    for src in style.get("sources", {}).values():
        if src.get("type") == "vector":
            # tileserver-gl erwartet mbtiles://{datakey} statt tiles-Array
            src.pop("tiles", None)
            src.pop("minzoom", None)
            src.pop("maxzoom", None)
            src["url"] = f"mbtiles://{{{data_key}}}"

    # tileserver-gl liefert Fonts selbst aus
    style["glyphs"] = "{fontstack}/{range}.pbf"
    style.pop("sprite", None)
    return style


def start_tileserver(mbtiles_name: str) -> None:
    global _container_id

    TMP_DIR.mkdir(parents=True, exist_ok=True)

    # MBTiles in Temp-Verzeichnis kopieren (Docker-Mount braucht lokale Dateien)
    src = WORK_DIR / mbtiles_name
    dst = TMP_DIR / "source.mbtiles"
    shutil.copy2(src, dst)

    # Adaptierten Style schreiben
    data_key = "v3"
    style = adapt_style(STYLE_SOURCE, data_key)
    (TMP_DIR / "style.json").write_text(json.dumps(style, indent=2), encoding="utf-8")

    # tileserver-gl config.json
    config = {
        "options": {
            "paths": {
                "root": "/usr/src/app/node_modules/tileserver-gl-styles",
                "fonts": "fonts",
                #"sprites": "sprites",
                "mbtiles": "/data",
            }
        },
        "data": {
            data_key: {"mbtiles": "source.mbtiles"}
        },
        "styles": {
            #STYLE_NAME: {"style": "style.json"}
            "basic-preview": {
                "style": "styles/basic-preview/style.json"
            }
        },
    }
    (TMP_DIR / "config.json").write_text(json.dumps(config, indent=2), encoding="utf-8")

    cmd = [
        "docker", "run", "-d", "--rm",
        "-p", f"{TILESERVER_PORT}:8080",
        "-v", f"{TMP_DIR}:/data",
        TILESERVER_IMAGE,
        "--config", "/data/config.json",
    ]

    print(f"[cmd] {' '.join(shlex.quote(part) for part in cmd)}")

    result = subprocess.run(cmd, capture_output=True, text=True)

    # Workaround fuer lokale Docker-Setups mit defektem credsStore.
    # Bei diesem Fehler pullen wir das Public-Image anonym ueber ein isoliertes DOCKER_CONFIG.
    if result.returncode != 0 and "error getting credentials" in result.stderr.lower():
        print("[warn] Docker-Credentials fehlerhaft, versuche anonymen Pull-Fallback ...")
        docker_cfg = TMP_DIR / ".docker-anon"
        docker_cfg.mkdir(parents=True, exist_ok=True)
        (docker_cfg / "config.json").write_text("{}", encoding="utf-8")
        env = dict(os.environ)
        env["DOCKER_CONFIG"] = str(docker_cfg)
        print(f"[cmd] DOCKER_CONFIG={env['DOCKER_CONFIG']} {' '.join(shlex.quote(part) for part in cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True, env=env)

    if result.returncode != 0:
        print(f"[error] Docker konnte nicht gestartet werden:\n{result.stderr.strip()}")
        sys.exit(1)

    _container_id = result.stdout.strip()
    print(f"[docker] Container gestartet: {_container_id[:12]}")


def wait_for_tileserver(timeout: int = 60) -> bool:
    url = f"http://localhost:{TILESERVER_PORT}/"
    print("[wait]  tileserver-gl startet", end="", flush=True)
    for _ in range(timeout):
        try:
            resp = requests.get(url, timeout=2)
            if resp.status_code == 200:
                print(" bereit.")
                return True
        except Exception:
            pass
        time.sleep(1)
        print(".", end="", flush=True)
    print(" Timeout!")
    return False


# ---------------------------------------------------------------------------
# Tiles herunterladen
# ---------------------------------------------------------------------------

def download_tile(
    session: requests.Session,
    z: int,
    x: int,
    y: int,
) -> tuple[int, int, int, bytes | None]:
    url = f"http://localhost:{TILESERVER_PORT}/styles/{STYLE_NAME}/{z}/{x}/{y}.png"
    try:
        resp = session.get(url, timeout=15)
        if resp.status_code == 200:
            return (z, x, y, resp.content)
    except Exception:
        pass
    return (z, x, y, None)


# ---------------------------------------------------------------------------
# Hauptprogramm
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Vektor-MBTiles → Raster-MBTiles via tileserver-gl (Docker)"
    )
    parser.add_argument(
        "input",
        nargs="?",
        help="Eingabe Vektor-MBTiles (Dateiname relativ zu map/tiles-germany/)",
        default="vogelsberg.mbtiles",
    )
    parser.add_argument(
        "output",
        nargs="?",
        help="Ausgabe Raster-MBTiles (Standard: <input>_raster.mbtiles)",
    )
    parser.add_argument(
        "--maxzoom",
        type=int,
        default=14,
        help="Maximaler Zoom-Level (Standard: 14)",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=4,
        help="Parallele Download-Threads (Standard: 4)",
    )
    args = parser.parse_args()

    input_path = WORK_DIR / args.input
    if not input_path.exists():
        print(f"[error] Datei nicht gefunden: {input_path}")
        return 1

    output_name = args.output or args.input.replace(".mbtiles", "_raster.mbtiles")
    output_path = WORK_DIR / output_name

    # Metadaten aus Quelle lesen
    meta = read_metadata(input_path)
    if meta.get("format") != "pbf":
        print(f"[error] Eingabedatei ist kein Vektor-MBTiles (format={meta.get('format')!r})")
        return 1

    zoom_min = int(meta.get("minzoom", 0))
    zoom_max = min(args.maxzoom, int(meta.get("maxzoom", 16)))
    bbox_str = meta.get("bounds", "")
    if not bbox_str:
        print("[error] Keine BBox in den MBTiles-Metadaten gefunden")
        return 1

    tiles = generate_tiles(bbox_str, zoom_min, zoom_max)

    print(f"[info]  Quelle:  {input_path.name}")
    print(f"[info]  Ausgabe: {output_path.name}")
    print(f"[info]  BBox:    {bbox_str}")
    print(f"[info]  Zoom:    z{zoom_min}–z{zoom_max}")
    print(f"[info]  Tiles:   {len(tiles):,}")

    # tileserver-gl starten
    start_tileserver(args.input)
    if not wait_for_tileserver(60):
        print("[error] tileserver-gl ist nicht erreichbar – abbruch")
        return 1

    # Raster-MBTiles befüllen
    conn = create_raster_mbtiles(output_path, meta, zoom_max)
    cur = conn.cursor()
    session = requests.Session()
    successful = 0
    failed = 0

    print(f"[render] Starte Rendering mit {args.workers} Threads ...")
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = {
            executor.submit(download_tile, session, z, x, y): (z, x, y)
            for z, x, y in tiles
        }
        with tqdm(total=len(tiles), unit="tiles") as pbar:
            for future in as_completed(futures):
                z, x, y, data = future.result()
                if data:
                    tms_y = flip_y(y, z)
                    cur.execute(
                        "INSERT OR REPLACE INTO tiles VALUES (?, ?, ?, ?)",
                        (z, x, tms_y, data),
                    )
                    successful += 1
                    if successful % 200 == 0:
                        conn.commit()
                else:
                    failed += 1
                pbar.update(1)

    conn.commit()
    conn.close()

    size_mb = output_path.stat().st_size / 1024 / 1024
    print(f"\n[done]  Erfolgreich: {successful:,}  |  Fehlgeschlagen: {failed:,}")
    print(f"[done]  Ausgabe: {output_path}  ({size_mb:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
