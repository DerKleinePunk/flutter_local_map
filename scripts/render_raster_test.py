#!/usr/bin/env python3
"""
Test-Implementierung: Vektor-MBTiles -> Raster-MBTiles (PNG), ohne render_raster.py zu aendern.

Diese Datei ist absichtlich separat und experimentell.
Sie bietet:
- Renderer-Auswahl: auto|tileserver_gl|maplibre_native
- GPU-Schalter: auto|on|off (nur fuer maplibre_native vorbereitet)
- Schnelltests mit --dry-run und --sample-tiles

Beispiele:
  python scripts/render_raster_test.py map/test/vogelsberg.mbtiles --maxzoom 12 --dry-run
  python scripts/render_raster_test.py map/test/vogelsberg.mbtiles --maxzoom 12 --sample-tiles 5000
  python scripts/render_raster_test.py map/tiles-germany/hessen.mbtiles --maxzoom 17 --workers 24
"""

import argparse
import atexit
import base64
import json
import math
import os
import random
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    import requests
    from requests.adapters import HTTPAdapter
    from tqdm import tqdm
except ImportError:
    print("[error] Fehlende Pakete. Bitte installieren: pip install requests tqdm")
    sys.exit(1)

TILESERVER_IMAGE = "maptiler/tileserver-gl"
TILESERVER_PORT = 7754
STYLE_NAME = "osm-bright"

SCRIPT_DIR = Path(__file__).parent
PROJECT_ROOT = SCRIPT_DIR.parent
DEFAULT_WORK_DIR = PROJECT_ROOT / "map" / "tiles-germany"
STYLES_ZIP_CANDIDATES = [
    SCRIPT_DIR / "styles.zip",
    DEFAULT_WORK_DIR / "styles.zip",
    PROJECT_ROOT / "map" / "test" / "styles.zip",
]

DEFAULT_WORKERS = max(8, (os.cpu_count() or 4) * 2)

_thread_local = threading.local()
_container_id: str | None = None
_tmp_dir: Path | None = None
_maplibre_error_logged = False
_maplibre_error_lock = threading.Lock()


class MapLibreWorker:
    def __init__(
        self,
        node_path: str,
        helper_path: Path,
        input_path: Path,
        assets_root: Path,
        gpu_mode: str,
    ) -> None:
        self._lock = threading.Lock()
        self._request_id = 0
        self._stderr_lines: list[str] = []
        cmd = [
            node_path,
            str(helper_path),
            "--worker",
            "1",
            "--input",
            str(input_path),
            "--style",
            STYLE_NAME,
            "--assets-root",
            str(assets_root),
            "--gpu",
            gpu_mode,
        ]
        self._process = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
        self._stderr_thread = threading.Thread(target=self._collect_stderr, daemon=True)
        self._stderr_thread.start()

        ready_line = self._read_line()
        if ready_line is None:
            self.close()
            raise RuntimeError("MapLibre-Worker konnte nicht gestartet werden")

        try:
            ready_payload = json.loads(ready_line)
        except json.JSONDecodeError as exc:
            self.close()
            raise RuntimeError(f"Ungueltige Worker-Ready-Antwort: {exc}") from exc

        if not ready_payload.get("ready"):
            self.close()
            raise RuntimeError(f"Worker meldet nicht ready: {ready_payload}")

    def _collect_stderr(self) -> None:
        stderr = self._process.stderr
        if stderr is None:
            return
        for line in stderr:
            line = line.strip()
            if line:
                self._stderr_lines.append(line)
                if len(self._stderr_lines) > 30:
                    self._stderr_lines = self._stderr_lines[-30:]

    def _read_line(self) -> str | None:
        if self._process.stdout is None:
            return None
        line = self._process.stdout.readline()
        if line == "":
            return None
        return line.strip()

    def render(self, z: int, x: int, y: int) -> bytes | None:
        with self._lock:
            if self._process.poll() is not None:
                return None

            self._request_id += 1
            payload = {
                "id": self._request_id,
                "z": z,
                "x": x,
                "y": y,
            }

            if self._process.stdin is None:
                return None
            self._process.stdin.write(json.dumps(payload) + "\n")
            self._process.stdin.flush()

            line = self._read_line()
            if line is None:
                return None

            try:
                response = json.loads(line)
            except json.JSONDecodeError:
                return None

            if response.get("id") != self._request_id:
                return None

            if not response.get("ok"):
                return None

            encoded = response.get("png")
            if not encoded:
                return None

            try:
                return base64.b64decode(encoded)
            except Exception:
                return None

    def diagnostics(self) -> str:
        if not self._stderr_lines:
            return ""
        return " | ".join(self._stderr_lines[-5:])

    def close(self) -> None:
        if self._process.poll() is None:
            if self._process.stdin is not None:
                try:
                    self._process.stdin.close()
                except OSError:
                    pass
            try:
                self._process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait(timeout=3)


def parse_int_list(raw_value: str) -> list[int]:
    return [
        int(value.strip())
        for value in raw_value.split(",")
        if value.strip()
    ]


def running_in_wsl() -> bool:
    if os.name == "nt":
        return False
    if os.environ.get("WSL_DISTRO_NAME"):
        return True
    try:
        return "microsoft" in Path("/proc/version").read_text(encoding="utf-8").lower()
    except OSError:
        return False


def default_tmp_dir() -> Path:
    env_tmp_dir = os.environ.get("RASTER_TMP_DIR")
    if env_tmp_dir:
        return Path(env_tmp_dir)
    if running_in_wsl():
        return Path(tempfile.gettempdir()) / "flutter_local_map_tileserver_test"
    return DEFAULT_WORK_DIR / "_tileserver_tmp_test"


def cleanup() -> None:
    global _container_id
    if _container_id:
        subprocess.run(["docker", "stop", _container_id], capture_output=True)
        _container_id = None
    if _tmp_dir and _tmp_dir.exists():
        shutil.rmtree(_tmp_dir, ignore_errors=True)


atexit.register(cleanup)


def lon_to_tile_x(lon: float, zoom: int) -> int:
    return int((lon + 180.0) / 360.0 * (1 << zoom))


def lat_to_tile_y(lat: float, zoom: int) -> int:
    lat_rad = math.radians(lat)
    return int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * (1 << zoom))


def flip_y(y: int, zoom: int) -> int:
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
    cur.execute("PRAGMA journal_mode=WAL")
    cur.execute("PRAGMA synchronous=NORMAL")
    cur.execute("PRAGMA temp_store=MEMORY")
    cur.execute("PRAGMA cache_size=-200000")
    cur.execute("CREATE TABLE metadata (name TEXT PRIMARY KEY, value TEXT)")
    cur.execute(
        """
        CREATE TABLE tiles (
            zoom_level  INTEGER,
            tile_column INTEGER,
            tile_row    INTEGER,
            tile_data   BLOB,
            PRIMARY KEY (zoom_level, tile_column, tile_row)
        )
        """
    )
    entries = {
        "name": source_meta.get("name", "Raster Tiles (Test)"),
        "type": "baselayer",
        "version": "1.0",
        "description": source_meta.get("description", "Raster-Tiles (Test) gerendert aus Vektor-MBTiles"),
        "format": "png",
        "bounds": source_meta.get("bounds", ""),
        "minzoom": source_meta.get("minzoom", "0"),
        "maxzoom": str(zoom_max),
        "attribution": "© OpenStreetMap contributors",
    }
    for k, v in entries.items():
        cur.execute("INSERT INTO metadata VALUES (?, ?)", (k, v))
    conn.commit()
    return conn


def resolve_input_path(input_arg: str) -> Path:
    candidate = Path(input_arg)
    if candidate.is_absolute() and candidate.exists():
        return candidate
    rel_to_root = PROJECT_ROOT / input_arg
    if rel_to_root.exists():
        return rel_to_root
    rel_to_work = DEFAULT_WORK_DIR / input_arg
    if rel_to_work.exists():
        return rel_to_work
    return candidate


def copy_file_with_progress(src: Path, dst: Path, chunk_size: int = 8 * 1024 * 1024) -> None:
    total_size = src.stat().st_size
    print(f"[copy]   {src.name} -> {dst}")

    with src.open("rb") as source_file, dst.open("wb") as target_file:
        with tqdm(
            total=total_size,
            unit="B",
            unit_scale=True,
            unit_divisor=1024,
            desc="Copy MBTiles",
        ) as progress:
            while True:
                chunk = source_file.read(chunk_size)
                if not chunk:
                    break
                target_file.write(chunk)
                progress.update(len(chunk))

    shutil.copystat(src, dst)


def unpack_styles_zip_to_tmp(tmp_dir: Path) -> None:
    styles_zip = next((path for path in STYLES_ZIP_CANDIDATES if path.exists()), None)
    if styles_zip is None:
        print("[error] Keine styles.zip gefunden. Erwartete Pfade:")
        for candidate in STYLES_ZIP_CANDIDATES:
            print(f"       - {candidate}")
        sys.exit(1)

    try:
        with zipfile.ZipFile(styles_zip, "r") as archive:
            archive.extractall(tmp_dir)
    except zipfile.BadZipFile:
        print(f"[error] Ungueltiges ZIP-Archiv: {styles_zip}")
        sys.exit(1)

    styles_dir = tmp_dir / "styles"
    expected_style = styles_dir / STYLE_NAME / "style.json"
    fonts_dir = tmp_dir / "fonts"

    if not expected_style.exists():
        print(f"[error] Erwarteter Style fehlt nach Entpacken: {expected_style}")
        sys.exit(1)

    if not fonts_dir.exists():
        print(f"[error] Erwarteter Fonts-Ordner fehlt nach Entpacken: {fonts_dir}")
        sys.exit(1)

    print(f"[styles] Entpackt nach {tmp_dir}: {styles_zip.name}")


def prepare_tileserver_data(tmp_dir: Path, input_path: Path, bbox_str: str) -> None:
    tmp_dir.mkdir(parents=True, exist_ok=True)

    dst = tmp_dir / "source.mbtiles"
    copy_file_with_progress(input_path, dst)
    unpack_styles_zip_to_tmp(tmp_dir)

    bounds = list(map(float, bbox_str.split(",")))
    config = {
        "options": {
            "paths": {
                "fonts": "fonts",
                "styles": "styles",
            }
        },
        "data": {
            "openmaptiles": {
                "mbtiles": "source.mbtiles"
            },
        },
        "styles": {
            STYLE_NAME: {
                "style": f"{STYLE_NAME}/style.json",
                "tilejson": {
                    "type": "overlay",
                    "bounds": bounds,
                },
            },
        },
    }

    (tmp_dir / "config.json").write_text(
        json.dumps(config, indent=2), encoding="utf-8"
    )
    print(f"[config] Using tileserver-gl built-in style: {STYLE_NAME}")


def start_tileserver(tmp_dir: Path, port: int, verbose_level: int = 2) -> str:
    cmd = [
        "docker", "run", "-d", "--rm",
        "-p", f"{port}:8080",
        "-v", f"{tmp_dir}:/data",
        TILESERVER_IMAGE,
        "--config", "/data/config.json",
        "--verbose", str(verbose_level),
    ]

    print(f"[cmd] {' '.join(shlex.quote(part) for part in cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0 and "error getting credentials" in result.stderr.lower():
        print("[warn] Docker-Credentials fehlerhaft, versuche anonymen Pull-Fallback ...")
        docker_cfg = tmp_dir / ".docker-anon"
        docker_cfg.mkdir(parents=True, exist_ok=True)
        (docker_cfg / "config.json").write_text("{}", encoding="utf-8")
        env = dict(os.environ)
        env["DOCKER_CONFIG"] = str(docker_cfg)
        result = subprocess.run(cmd, capture_output=True, text=True, env=env)

    if result.returncode != 0:
        print(f"[error] Docker konnte nicht gestartet werden:\n{result.stderr.strip()}")
        sys.exit(1)

    container_id = result.stdout.strip()
    print(f"[docker] Container gestartet: {container_id} (Port {port})")
    return container_id


def wait_for_tileserver(port: int, timeout: int = 60) -> bool:
    url = f"http://localhost:{port}/"
    print(f"[wait]  tileserver-gl auf Port {port} startet", end="", flush=True)
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


def maplibre_native_available() -> bool:
    node = shutil.which("node")
    if node is None:
        return False
    helper = SCRIPT_DIR / "render_maplibre_native.js"
    return helper.exists()


def maplibre_native_unavailable_reason() -> str:
    node = shutil.which("node")
    helper = SCRIPT_DIR / "render_maplibre_native.js"
    if node is None:
        return "node nicht gefunden"
    if not helper.exists():
        return f"Helper fehlt: {helper}"
    return "unbekannter Grund"


def maplibre_native_preflight(input_path: Path, gpu_mode: str) -> tuple[bool, str]:
    helper = SCRIPT_DIR / "render_maplibre_native.js"
    node = shutil.which("node")
    if node is None:
        return (False, "node nicht gefunden")
    if not helper.exists():
        return (False, f"Helper fehlt: {helper}")

    cmd = [
        node,
        str(helper),
        "--healthcheck",
        "1",
        "--input",
        str(input_path),
        "--style",
        STYLE_NAME,
        "--z",
        "0",
        "--x",
        "0",
        "--y",
        "0",
        "--gpu",
        gpu_mode,
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
    except Exception as exc:
        return (False, f"Preflight-Start fehlgeschlagen: {exc}")

    if result.returncode == 0:
        return (True, "ok")

    stderr = (result.stderr or "").strip()
    stdout = (result.stdout or "").strip()
    message = stderr or stdout or f"Exit-Code {result.returncode}"
    return (False, message)


def maplibre_native_capabilities() -> tuple[bool, dict[str, bool], str]:
    helper = SCRIPT_DIR / "render_maplibre_native.js"
    node = shutil.which("node")
    if node is None:
        return (False, {}, "node nicht gefunden")
    if not helper.exists():
        return (False, {}, f"Helper fehlt: {helper}")

    cmd = [node, str(helper), "--capabilities", "1"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
    except Exception as exc:
        return (False, {}, f"Capabilities-Aufruf fehlgeschlagen: {exc}")

    if result.returncode != 0:
        message = (result.stderr or result.stdout or "").strip() or f"Exit-Code {result.returncode}"
        return (False, {}, message)

    try:
        parsed = json.loads((result.stdout or "").strip() or "{}")
    except json.JSONDecodeError as exc:
        return (False, {}, f"Ungueltige Capabilities-Antwort: {exc}")

    return (True, {
        "healthcheck": bool(parsed.get("healthcheck", False)),
        "render": bool(parsed.get("render", False)),
        "worker": bool(parsed.get("worker", False)),
    }, "ok")


def start_maplibre_workers(
    count: int,
    input_path: Path,
    assets_root: Path,
    gpu_mode: str,
) -> list[MapLibreWorker]:
    helper = SCRIPT_DIR / "render_maplibre_native.js"
    node = shutil.which("node")
    if node is None:
        raise RuntimeError("node nicht gefunden")
    if not helper.exists():
        raise RuntimeError(f"Helper fehlt: {helper}")

    workers: list[MapLibreWorker] = []
    for _ in range(count):
        workers.append(
            MapLibreWorker(
                node_path=node,
                helper_path=helper,
                input_path=input_path,
                assets_root=assets_root,
                gpu_mode=gpu_mode,
            )
        )
    return workers


def download_tile_tileserver(z: int, x: int, y: int, port: int) -> bytes | None:
    session = getattr(_thread_local, "session", None)
    if session is None:
        session = requests.Session()
        adapter = HTTPAdapter(pool_connections=1, pool_maxsize=1)
        session.mount("http://", adapter)
        session.mount("https://", adapter)
        _thread_local.session = session

    url = f"http://localhost:{port}/styles/{STYLE_NAME}/{z}/{x}/{y}.png"
    try:
        resp = session.get(url, timeout=20)
        if resp.status_code == 200:
            return resp.content
    except Exception:
        return None
    return None


def download_tile_maplibre_native(
    z: int,
    x: int,
    y: int,
    workers: list[MapLibreWorker],
) -> bytes | None:
    global _maplibre_error_logged
    if not workers:
        return None

    worker = workers[(z + x + y) % len(workers)]
    data = worker.render(z, x, y)
    if data is not None:
        return data

    with _maplibre_error_lock:
        if not _maplibre_error_logged:
            diag = worker.diagnostics()
            message = diag or "keine zusaetzlichen stderr-details"
            print(f"[error] maplibre worker fehlgeschlagen: {message}")
            _maplibre_error_logged = True
    return None


def maybe_sample_tiles(tiles: list[tuple[int, int, int]], sample_tiles: int | None) -> list[tuple[int, int, int]]:
    if sample_tiles is None or sample_tiles <= 0:
        return tiles
    if sample_tiles >= len(tiles):
        return tiles
    random.seed(42)
    sampled = random.sample(tiles, sample_tiles)
    sampled.sort()
    return sampled


def main() -> int:
    global _container_id, _tmp_dir

    parser = argparse.ArgumentParser(
        description="Test: Vektor-MBTiles -> Raster-MBTiles (PNG)"
    )
    parser.add_argument(
        "input",
        help="Pfad zur Eingabe-Vektor-MBTiles (absolut oder relativ zum Projekt)"
    )
    parser.add_argument(
        "output",
        nargs="?",
        help="Ausgabe-MBTiles (Standard: <input>_raster_test.mbtiles im selben Ordner)"
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
        default=DEFAULT_WORKERS,
        help=f"Parallele Worker (Standard: {DEFAULT_WORKERS})",
    )
    parser.add_argument(
        "--maplibre-workers",
        type=int,
        default=max(1, min(8, (os.cpu_count() or 4) // 2)),
        help="Anzahl persistenter maplibre-native Worker-Prozesse (Standard: CPU/2, max 8)",
    )
    parser.add_argument(
        "--renderer",
        choices=["auto", "tileserver_gl", "maplibre_native"],
        default="auto",
        help="Rendering-Engine (Standard: auto)",
    )
    parser.add_argument(
        "--gpu",
        choices=["auto", "on", "off"],
        default="auto",
        help="GPU-Mode fuer maplibre_native (Standard: auto)",
    )
    parser.add_argument(
        "--sample-tiles",
        type=int,
        default=None,
        help="Nur N zufaellige Tiles rendern (Schnelltest)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Nur planen/validieren, kein Rendering starten",
    )
    parser.add_argument(
        "--tileserver-verbose",
        type=int,
        default=2,
        choices=[1, 2, 3],
        help="tileserver-gl Loglevel (1-3)",
    )
    parser.add_argument(
        "--tmp-dir",
        help="Arbeitsverzeichnis fuer tileserver-Dateien",
    )
    args = parser.parse_args()

    start_time = time.monotonic()

    input_path = resolve_input_path(args.input)
    if not input_path.exists():
        print(f"[error] Datei nicht gefunden: {input_path}")
        return 1

    if args.output:
        output_path = resolve_input_path(args.output)
    else:
        output_path = input_path.with_name(input_path.stem + "_raster_test.mbtiles")

    meta = read_metadata(input_path)
    if meta.get("format") != "pbf":
        print(f"[error] Eingabedatei ist kein Vektor-MBTiles (format={meta.get('format')!r})")
        return 1

    zoom_min = int(meta.get("minzoom", 0))
    zoom_max = min(args.maxzoom, int(meta.get("maxzoom", 16)))
    bbox_str = meta.get("bounds", "")
    if not bbox_str:
        print("[error] Keine bounds in den MBTiles-Metadaten gefunden")
        return 1

    all_tiles = generate_tiles(bbox_str, zoom_min, zoom_max)
    tiles = maybe_sample_tiles(all_tiles, args.sample_tiles)

    selected_renderer = args.renderer
    if selected_renderer == "auto":
        selected_renderer = "maplibre_native" if maplibre_native_available() else "tileserver_gl"
    elif selected_renderer == "maplibre_native" and not maplibre_native_available():
        print(
            "[error] renderer=maplibre_native angefordert, aber nicht verfuegbar: "
            f"{maplibre_native_unavailable_reason()}"
        )
        print("[hint] Fuer Testlauf entweder --renderer auto/tileserver_gl nutzen oder den Node-Helper einrichten.")
        return 1

    if selected_renderer == "maplibre_native":
        preflight_ok, preflight_message = maplibre_native_preflight(input_path, args.gpu)
        if not preflight_ok:
            if args.renderer == "auto":
                print(f"[warn] maplibre_native Preflight fehlgeschlagen ({preflight_message}).")
                print("[warn] Schalte fuer diesen Lauf auf tileserver_gl um.")
                selected_renderer = "tileserver_gl"
            else:
                print(f"[error] maplibre_native Preflight fehlgeschlagen: {preflight_message}")
                print("[hint] Fuer Testlauf --renderer auto/tileserver_gl verwenden oder Helper fertig implementieren.")
                return 1

    if selected_renderer == "maplibre_native":
        caps_ok, caps, caps_message = maplibre_native_capabilities()
        if not caps_ok:
            if args.renderer == "auto":
                print(f"[warn] maplibre_native Capabilities nicht lesbar ({caps_message}).")
                print("[warn] Schalte fuer diesen Lauf auf tileserver_gl um.")
                selected_renderer = "tileserver_gl"
            else:
                print(f"[error] maplibre_native Capabilities fehlgeschlagen: {caps_message}")
                return 1
        elif not caps.get("render", False):
            if args.renderer == "auto":
                print("[warn] maplibre-native ist installiert, aber Renderfunktion noch nicht implementiert.")
                print("[warn] Schalte fuer diesen Lauf auf tileserver_gl um.")
                selected_renderer = "tileserver_gl"
            else:
                print("[error] renderer=maplibre_native angefordert, aber Renderfunktion ist noch nicht implementiert.")
                print("[hint] Nutze --renderer auto oder --renderer tileserver_gl fuer echte Testlaeufe.")
                return 1
        elif not caps.get("worker", False):
            if args.renderer == "auto":
                print("[warn] maplibre-native ohne worker-capability erkannt.")
                print("[warn] Schalte fuer diesen Lauf auf tileserver_gl um.")
                selected_renderer = "tileserver_gl"
            else:
                print("[error] renderer=maplibre_native angefordert, aber worker-capability fehlt.")
                return 1

    print(f"[info]  Quelle:    {input_path}")
    print(f"[info]  Ausgabe:   {output_path}")
    print(f"[info]  Zoom:      z{zoom_min}-z{zoom_max}")
    print(f"[info]  BBox:      {bbox_str}")
    print(f"[info]  Alle Tiles:{len(all_tiles):,}")
    if args.sample_tiles:
        print(f"[info]  Sample:    {len(tiles):,}")
    print(f"[info]  Renderer:  {selected_renderer} (requested: {args.renderer})")
    print(f"[info]  GPU-Mode:  {args.gpu}")
    if selected_renderer == "maplibre_native":
        print(f"[info]  ML-Worker: {max(1, args.maplibre_workers)}")

    if args.dry_run:
        print("[done]  Dry-Run abgeschlossen, kein Rendering gestartet.")
        return 0

    _tmp_dir = Path(args.tmp_dir) if args.tmp_dir else default_tmp_dir()

    port = TILESERVER_PORT
    tileserver_ready = False
    maplibre_workers: list[MapLibreWorker] = []

    if selected_renderer in {"tileserver_gl", "maplibre_native"}:
        prepare_tileserver_data(_tmp_dir, input_path, bbox_str)

    if selected_renderer == "tileserver_gl":
        _container_id = start_tileserver(_tmp_dir, port, verbose_level=args.tileserver_verbose)
        tileserver_ready = wait_for_tileserver(port, timeout=60)
        if not tileserver_ready:
            print("[error] tileserver-gl ist nicht erreichbar")
            return 1

    if selected_renderer == "maplibre_native":
        try:
            maplibre_workers = start_maplibre_workers(
                count=max(1, args.maplibre_workers),
                input_path=input_path,
                assets_root=_tmp_dir,
                gpu_mode=args.gpu,
            )
        except RuntimeError as exc:
            print(f"[error] maplibre worker-start fehlgeschlagen: {exc}")
            return 1

    conn = create_raster_mbtiles(output_path, meta, zoom_max)
    cur = conn.cursor()
    successful = 0
    failed = 0
    pending_rows: list[tuple[int, int, int, bytes]] = []
    batch_size = max(200, args.workers * 4)

    def flush_pending_rows() -> None:
        nonlocal pending_rows
        if not pending_rows:
            return
        cur.executemany(
            "INSERT OR REPLACE INTO tiles VALUES (?, ?, ?, ?)",
            pending_rows,
        )
        conn.commit()
        pending_rows = []

    print(f"[render] Starte Rendering mit {args.workers} Workern ...")

    def render_one(tile: tuple[int, int, int]) -> tuple[int, int, int, bytes | None]:
        z, x, y = tile
        if selected_renderer == "maplibre_native":
            data = download_tile_maplibre_native(z, x, y, maplibre_workers)
            if data is not None:
                return z, x, y, data
            return z, x, y, None

        data = download_tile_tileserver(z, x, y, port)
        return z, x, y, data

    executor_workers = args.workers
    if selected_renderer == "maplibre_native":
        executor_workers = max(1, args.maplibre_workers)

    with ThreadPoolExecutor(max_workers=executor_workers) as executor:
        futures = {executor.submit(render_one, tile): tile for tile in tiles}
        with tqdm(total=len(tiles), unit="tiles") as pbar:
            for future in as_completed(futures):
                z, x, y, data = future.result()
                if data:
                    tms_y = flip_y(y, z)
                    pending_rows.append((z, x, tms_y, data))
                    successful += 1
                    if len(pending_rows) >= batch_size:
                        flush_pending_rows()
                else:
                    failed += 1
                pbar.update(1)

    flush_pending_rows()
    conn.commit()
    conn.close()

    for worker in maplibre_workers:
        worker.close()

    size_mb = output_path.stat().st_size / 1024 / 1024
    elapsed = time.monotonic() - start_time
    h = int(elapsed // 3600)
    m = int((elapsed % 3600) // 60)
    s = int(elapsed % 60)
    tiles_per_second = (successful / elapsed) if elapsed > 0 else 0.0
    processed_per_second = ((successful + failed) / elapsed) if elapsed > 0 else 0.0

    print(f"[done]  Erfolgreich: {successful:,} | Fehlgeschlagen: {failed:,}")
    print(f"[done]  Ausgabe:    {output_path} ({size_mb:.1f} MB)")
    print(f"[done]  Dauer:      {h:02d}:{m:02d}:{s:02d}")
    print(f"[done]  Tiles/s:    {tiles_per_second:.2f} erfolgreich | {processed_per_second:.2f} verarbeitet")

    if failed > 0:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
