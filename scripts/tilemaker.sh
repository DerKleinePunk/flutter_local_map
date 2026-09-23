#!/usr/bin/env bash
set -euo pipefail

SCRIPT_START_TS="$(date +%s)"

print_runtime() {
  local end_ts elapsed hours minutes seconds
  end_ts="$(date +%s)"
  elapsed=$((end_ts - SCRIPT_START_TS))
  hours=$((elapsed / 3600))
  minutes=$(((elapsed % 3600) / 60))
  seconds=$((elapsed % 60))
  printf '[time] Laufzeit: %02d:%02d:%02d\n' "$hours" "$minutes" "$seconds"
}

trap print_runtime EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Arbeitsverzeichnis fuer Quelldaten, Zwischenspeicher und Ergebnis.
#
# Umstellbar, weil ein podman-remote aus Podman Desktop die Pfade auf dem
# Server aufloest: der laeuft in einer anderen WSL-Distribution und sieht
# nichts unter /home, sondern nur was unter /mnt/wsl liegt. Dann zeigt
# TILEMAKER_WORK_DIR auf ein Verzeichnis der geteilten Platte, etwa
# /mnt/wsl/code/tiles-germany.
WORK_DIR="${TILEMAKER_WORK_DIR:-$PROJECT_ROOT/map/tiles-germany}"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

PBF_FILE="germany-latest.osm.pbf"
WATER_ZIP="water-polygons-split-4326.zip"
COASTLINE_DIR="coastline"

show_usage() {
  echo "Nutzung: ./tilemaker.sh [vogelsberg|braunschweig|hessen] [raster|--raster]"
  echo ""
  echo "  ohne Parameter:    Germany Vector-MBTiles"
  echo "  vogelsberg:        Testgebiet Fulda/Vogelsberg (BBox)"
  echo "  braunschweig:      Braunschweig mit Umland (BBox)"
  echo "  hessen:            Hessen (BBox)"
  echo "  raster|--raster:   zusaetzlich Raster-MBTiles aus Vektor-MBTiles erzeugen"
  echo "                     benoetigt gueltiges styles.zip (z. B. scripts/styles.zip)"
  echo ""
  echo "Optionale Umgebungsvariablen:"
  echo "  TILEMAKER_WORK_DIR (Arbeitsverzeichnis; Standard map/tiles-germany)"
  echo "                     noetig bei podman-remote, dessen Server nur"
  echo "                     Pfade unter /mnt/wsl sieht"
  echo "  CONTAINER_CMD  (docker|podman; sonst wird automatisch gewaehlt)"
  echo "  FORCE_REBUILD=1 (baut neu, aber per tilemaker --merge in die"
  echo "                   vorhandene Datei - fuer einen sauberen Neubau die"
  echo "                   Zieldatei stattdessen vorher wegschieben)"
  echo "  SKIP_PBF_MD5=1 (nur wenn Geofabriks Pruefsumme nachweislich einen"
  echo "                  aelteren Tagesstand beschreibt als die .pbf)"
  echo ""
  echo "Optionale Umgebungsvariablen fuer Raster-Schritt:"
  echo "  RASTER_MAXZOOM (default: 17)"
  echo "  RASTER_WORKERS (default: 8)"
  echo "  RASTER_FORMAT  (default: png; 'jpeg' fuer kleinere Tiles ~3-5x)"
  echo "  RASTER_TILESERVER_INSTANCES (default: auto in render_raster.py)"
  echo "  RASTER_MAX_RENDERER_POOL_SIZES (z. B. 24 oder 24,12,6)"
  echo "  RASTER_MIN_RENDERER_POOL_SIZES (z. B. 24 oder 24,12,6)"
  echo "  RASTER_CONTOURS (Dateiname einer Konturlinien-MBTiles in map/tiles-germany/,"
  echo "                   z. B. vogelsberg_contours.mbtiles – werden in Raster-Tiles eingebacken)"
}

# Vogelsberg: Testgebiet rund um Fulda / Vogelsberg
# Südgrenze auf 50.22 erweitert damit die GPS-Adnan-Tour vollständig abgedeckt ist
VOGELSBERG_BBOX="8.9,50.22,9.9,50.85"

# Braunschweig mit Umland: Wolfsburg, Wolfenbuettel, Salzgitter und Peine sind mit enthalten
BRAUNSCHWEIG_BBOX="10.28,52.12,10.78,52.42"

# Hessen: uebernommen aus den bounds von hessen_extract.mbtiles, damit der
# gebaute Ausschnitt deckungsgleich mit dem bisherigen bleibt.
HESSEN_BBOX="7.7726,49.3963,10.2358,51.6569"

BBOX_ARG=()
GENERATE_RASTER=0
REGION="germany"

for arg in "$@"; do
  case "$arg" in
    vogelsberg)
      REGION="vogelsberg"
      ;;
    braunschweig)
      REGION="braunschweig"
      ;;
    hessen)
      REGION="hessen"
      ;;
    raster|--raster)
      GENERATE_RASTER=1
      ;;
    -h|--help)
      show_usage
      exit 0
      ;;
    *)
      echo "[error] Unbekannter Parameter: $arg"
      show_usage
      exit 1
      ;;
  esac
done

# Container-Laufzeit: docker oder podman, je nachdem was laeuft.
#
# `command -v docker` reicht als Pruefung nicht: unter WSL zeigt das oft auf
# die Windows-Installation, und ohne aktivierte WSL-Integration meldet sie
# nur "The command 'docker' could not be found in this WSL 2 distro".
# Deshalb wird docker zusaetzlich mit `docker info` angesprochen.
#
# Ueberschreibbar per CONTAINER_CMD=podman ./tilemaker.sh
CONTAINER_CMD="${CONTAINER_CMD:-}"
if [ -z "$CONTAINER_CMD" ]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
  elif command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
  else
    echo "[error] Weder docker noch podman ist erreichbar."
    echo "        docker: WSL-Integration in Docker Desktop einschalten"
    echo "                (Settings -> Resources -> WSL Integration)"
    echo "        podman: sudo apt install podman"
    echo ""
    echo "        Achtung: ein podman-remote aus Podman Desktop reicht NICHT."
    echo "        Der Server laeuft dann in einer anderen WSL-Distribution und"
    echo "        loest -v dort auf, sieht also weder $WORK_DIR noch sonst"
    echo "        etwas unter /home - der Lauf scheitert an"
    echo "        'statfs ...: no such file or directory'. Gebraucht wird ein"
    echo "        podman in DIESER Distribution."
    exit 1
  fi
fi
echo "[container] Laufzeit: $CONTAINER_CMD"

# -it nur wenn ein Terminal dranhaengt, sonst scheitert der Lauf in einer
# Pipeline oder im Hintergrund an "the input device is not a TTY".
TTY_ARG=()
if [ -t 0 ]; then
  TTY_ARG=(-it)
fi

case "$REGION" in
  vogelsberg)
    echo "[bbox] Vogelsberg-Testgebiet: $VOGELSBERG_BBOX"
    BBOX_ARG+=(--bbox "$VOGELSBERG_BBOX")
    OUTPUT_MBTILES="vogelsberg.mbtiles"
    ;;
  braunschweig)
    echo "[bbox] Braunschweig mit Umland: $BRAUNSCHWEIG_BBOX"
    BBOX_ARG+=(--bbox "$BRAUNSCHWEIG_BBOX")
    OUTPUT_MBTILES="braunschweig.mbtiles"
    ;;
  hessen)
    echo "[bbox] Hessen: $HESSEN_BBOX"
    BBOX_ARG+=(--bbox "$HESSEN_BBOX")
    OUTPUT_MBTILES="hessen.mbtiles"
    ;;
  *)
    OUTPUT_MBTILES="germany.mbtiles"
    ;;
esac

# Deutschland PBF (~4 GB)
PBF_URL="https://download.geofabrik.de/europe/germany-latest.osm.pbf"
PBF_MD5_URL="${PBF_URL}.md5"
PBF_MD5_FILE="${PBF_FILE}.md5"

_check_pbf_md5() {
  local expected actual
  echo "[md5] Lade Prüfsumme herunter..."
  wget -q -O "$PBF_MD5_FILE" "$PBF_MD5_URL" || { echo "[warning] Prüfsummen-Download fehlgeschlagen"; return 1; }
  echo "[md5] Prüfe Integrität von $PBF_FILE"

  # Geofabrik liefert in *.md5 oft einen versionierten Dateinamen
  # (z. B. germany-260505.osm.pbf) statt germany-latest.osm.pbf.
  # Deshalb vergleichen wir nur den Hashwert und ignorieren den Dateinamen.
  expected="$(awk '{print $1; exit}' "$PBF_MD5_FILE" || true)"
  if [ -z "$expected" ]; then
    echo "[warning] Konnte erwartete Prüfsumme nicht lesen: $PBF_MD5_FILE"
    return 1
  fi

  actual="$(md5sum "$PBF_FILE" | awk '{print $1}')"
  if [ "$actual" = "$expected" ]; then
    echo "[md5] Prüfsumme OK"
    return 0
  else
    echo "[md5] Prüfsumme FEHLGESCHLAGEN"
    echo "       erwartet: $expected"
    echo "       erhalten: $actual"
    return 1
  fi
}

# Laedt nach "$PBF_FILE.part" und schiebt erst nach bestandener Pruefung
# darueber. Ein Fehlschlag kostet so nie die vorhandene Datei - bei 4,6 GB
# ist das der Unterschied zwischen "nochmal probieren" und "nochmal laden".
_download_pbf() {
  echo "[download] Lade $PBF_FILE herunter"
  wget -O "$PBF_FILE.part" "$PBF_URL"
  mv -f "$PBF_FILE.part" "$PBF_FILE"
}

if [ "${SKIP_PBF_MD5:-0}" = "1" ]; then
  # Geofabrik veroeffentlicht die .md5 gelegentlich spaeter als die .pbf:
  # dann beschreibt die Pruefsumme einen aelteren Tagesstand, und die
  # Pruefung schlaegt fehl, obwohl die Datei vollstaendig ist. Erkennbar
  # daran, dass die Dateigroesse exakt dem Content-Length des Servers
  # entspricht und die .md5 auf einen anderen Dateinamen zeigt.
  echo "[md5] UEBERSPRUNGEN (SKIP_PBF_MD5=1) - Integritaet ist ungeprueft"
  if [ ! -f "$PBF_FILE" ]; then
    _download_pbf
  fi
elif [ -f "$PBF_FILE" ]; then
  echo "[check] $PBF_FILE gefunden, prüfe Prüfsumme..."
  if ! _check_pbf_md5; then
    echo "[download] Prüfsumme passt nicht – lade $PBF_FILE erneut"
    _download_pbf
    _check_pbf_md5 || {
      echo "[error] MD5-Prüfung nach Neudownload fehlgeschlagen"
      echo "        Stimmt die Dateigroesse mit dem Server ueberein und nennt"
      echo "        die .md5 einen anderen Dateinamen, hinkt Geofabriks"
      echo "        Pruefsumme nur hinterher. Dann: SKIP_PBF_MD5=1 $0 $*"
      exit 1
    }
  fi
else
  _download_pbf
  _check_pbf_md5 || { echo "[error] MD5-Prüfung nach Download fehlgeschlagen"; exit 1; }
fi

# Küsten-/Wasserdaten
if [ -d "$COASTLINE_DIR" ] && [ -f "$COASTLINE_DIR/water_polygons.shp" ]; then
  echo "[skip] Küstendaten sind bereits entpackt in $COASTLINE_DIR"
else
  if [ -f "$WATER_ZIP" ]; then
    echo "[skip] $WATER_ZIP ist bereits vorhanden"
  else
    echo "[download] Lade $WATER_ZIP herunter"
    wget -O "$WATER_ZIP" https://osmdata.openstreetmap.de/download/water-polygons-split-4326.zip
  fi

  echo "[extract] Entpacke Küstendaten nach $COASTLINE_DIR"
  unzip -o "$WATER_ZIP" -d "$COASTLINE_DIR"

  # Some archives contain an extra top-level folder. Flatten it so
  # water_polygons.* is always directly in $COASTLINE_DIR.
  if [ ! -f "$COASTLINE_DIR/water_polygons.shp" ]; then
    nested_shp="$(find "$COASTLINE_DIR" -type f -name 'water_polygons.shp' | head -n 1 || true)"
    if [ -n "$nested_shp" ]; then
      nested_dir="$(dirname "$nested_shp")"
      if [ "$nested_dir" != "$COASTLINE_DIR" ]; then
        echo "[extract] Verschiebe Dateien aus Unterordner nach $COASTLINE_DIR"
        find "$nested_dir" -mindepth 1 -maxdepth 1 -exec mv -f {} "$COASTLINE_DIR"/ \;
      fi
    fi
  fi
fi

if ! [ -f "ne_10m_antarctic_ice_shelves_polys.zip" ]; then
  curl --proto '=https' --tlsv1.3 -sSfO https://naciscdn.org/naturalearth/10m/physical/ne_10m_antarctic_ice_shelves_polys.zip
fi

mkdir -p landcover
if [ -d "landcover/ne_10m_antarctic_ice_shelves_polys" ]; then
  echo "[skip] landcover/ne_10m_antarctic_ice_shelves_polys ist bereits entpackt"
else
  mkdir -p landcover/ne_10m_antarctic_ice_shelves_polys
  unzip -o ne_10m_antarctic_ice_shelves_polys.zip -d landcover/ne_10m_antarctic_ice_shelves_polys
fi

if ! [ -f "ne_10m_urban_areas.zip" ]; then
  curl --proto '=https' --tlsv1.3 -sSfO https://naciscdn.org/naturalearth/10m/cultural/ne_10m_urban_areas.zip
fi

if [ -d "landcover/ne_10m_urban_areas" ]; then
  echo "[skip] landcover/ne_10m_urban_areas ist bereits entpackt"
else
  mkdir -p landcover/ne_10m_urban_areas
  unzip -o ne_10m_urban_areas.zip -d landcover/ne_10m_urban_areas
fi


if ! [ -f "ne_10m_glaciated_areas.zip" ]; then
  curl --proto '=https' --tlsv1.3 -sSfO https://naciscdn.org/naturalearth/10m/physical/ne_10m_glaciated_areas.zip
fi

if [ -d "landcover/ne_10m_glaciated_areas" ]; then
  echo "[skip] landcover/ne_10m_glaciated_areas ist bereits entpackt"
else
  mkdir -p landcover/ne_10m_glaciated_areas
  unzip -o ne_10m_glaciated_areas.zip -d landcover/ne_10m_glaciated_areas
fi

NEEDS_VECTOR_BUILD=1
if [ -f "$OUTPUT_MBTILES" ] && [ "${FORCE_REBUILD:-0}" != "1" ]; then
  echo "[skip] $OUTPUT_MBTILES existiert bereits."
  echo "       Setze FORCE_REBUILD=1, um die Datei neu zu erzeugen."
  NEEDS_VECTOR_BUILD=0
fi

if [ ! -f "$COASTLINE_DIR/water_polygons.shp" ] || [ ! -f "$COASTLINE_DIR/water_polygons.shx" ] || [ ! -f "$COASTLINE_DIR/water_polygons.dbf" ]; then
  echo "[error] Fehlende Shapefile-Bestandteile in $COASTLINE_DIR"
  echo "        Erwartet: water_polygons.shp, water_polygons.shx, water_polygons.dbf"
  exit 1
fi

if [ "$NEEDS_VECTOR_BUILD" = "1" ]; then
  TILEMAKER_REBUILD_ARG=()
  if [ "${FORCE_REBUILD:-0}" = "1" ]; then
    TILEMAKER_REBUILD_ARG+=(--merge)
  fi

  # Anzahl Threads fuer tilemaker: Standard = alle verfuegbaren CPU-Kerne.
  # Mit --threads 0 nutzt tilemaker automatisch alle Kerne.
  # Kann per Env-Variable TILEMAKER_THREADS ueberschrieben werden.
  TILEMAKER_THREADS="${TILEMAKER_THREADS:-0}"

  "$CONTAINER_CMD" run "${TTY_ARG[@]}" --rm --pull always \
    -w /data \
    -v "$WORK_DIR:/data" \
    -v "$PROJECT_ROOT:/workspace" \
    ghcr.io/systemed/tilemaker:master \
      --input /data/$PBF_FILE \
      --output /data/$OUTPUT_MBTILES \
      --config /workspace/scripts/tilemaker/config-openmaptiles-z17.json \
      --process /usr/src/app/resources/process-openmaptiles.lua \
      --fast \
      --threads "$TILEMAKER_THREADS" \
      "${TILEMAKER_REBUILD_ARG[@]}" \
      "${BBOX_ARG[@]}" \
      --store /data/temp
fi

# Ensure a local virtualenv exists for Python tooling.
SYSTEM_PYTHON="python3"
if ! command -v "$SYSTEM_PYTHON" >/dev/null 2>&1; then
  SYSTEM_PYTHON="python"
  if ! command -v "$SYSTEM_PYTHON" >/dev/null 2>&1; then
    echo "[error] Python ist nicht installiert oder nicht im PATH"
    exit 1
  fi
fi

VENV_ACTIVATE=".venv/bin/activate"
if [ ! -f "$VENV_ACTIVATE" ]; then
  echo "[python] Erstelle virtuelle Umgebung in .venv"
  "$SYSTEM_PYTHON" -m venv .venv

  # shellcheck disable=SC1091
  source "$VENV_ACTIVATE"

  if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
    echo "[python] Installiere Abhaengigkeiten aus $SCRIPT_DIR/requirements.txt"
    python -m pip install --upgrade pip
    python -m pip install -r "$SCRIPT_DIR/requirements.txt"
  else
    echo "[warning] requirements.txt nicht gefunden: $SCRIPT_DIR/requirements.txt"
  fi
else
  # shellcheck disable=SC1091
  source "$VENV_ACTIVATE"
fi

PYTHON_BIN="python"

# Extract searchable names database
NAMES_DB_OUTPUT="${OUTPUT_MBTILES%.mbtiles}_names.db"
if [ -f "$NAMES_DB_OUTPUT" ] && [ "${FORCE_REBUILD:-0}" != "1" ]; then
  echo "[skip] $NAMES_DB_OUTPUT existiert bereits"
else
  if [ -f "$NAMES_DB_OUTPUT" ]; then
    echo "[names] FORCE_REBUILD=1 gesetzt, entferne vorhandene Datei: $NAMES_DB_OUTPUT"
    rm -f "$NAMES_DB_OUTPUT"
  fi

  echo "[names] Extrahiere suchbare Namen aus $OUTPUT_MBTILES"
  if "$PYTHON_BIN" "$SCRIPT_DIR/extract_names_to_sqlite.py" \
      "$WORK_DIR/$OUTPUT_MBTILES" \
      "$WORK_DIR/$NAMES_DB_OUTPUT"; then
    echo "[ok] Erstellt: $NAMES_DB_OUTPUT"
  else
    echo "[warning] Namen-Extraktion fehlgeschlagen, fortfahren..."
  fi
fi

if [ "$GENERATE_RASTER" = "1" ]; then
  RASTER_OUTPUT="${OUTPUT_MBTILES%.mbtiles}_raster.mbtiles"
  RASTER_MAXZOOM="${RASTER_MAXZOOM:-17}"
  RASTER_WORKERS="${RASTER_WORKERS:-8}"
  RASTER_FORMAT="${RASTER_FORMAT:-png}"
  RASTER_TILESERVER_INSTANCES="${RASTER_TILESERVER_INSTANCES:-}"
  RASTER_MAX_RENDERER_POOL_SIZES="${RASTER_MAX_RENDERER_POOL_SIZES:-}"
  RASTER_MIN_RENDERER_POOL_SIZES="${RASTER_MIN_RENDERER_POOL_SIZES:-}"
  RASTER_CONTOURS="${RASTER_CONTOURS:-}"
  TILESERVER_INSTANCES_ARG=()
  MAX_RENDERER_POOL_SIZES_ARG=()
  MIN_RENDERER_POOL_SIZES_ARG=()
  CONTOURS_ARG=()
  if [ -n "$RASTER_TILESERVER_INSTANCES" ]; then
    TILESERVER_INSTANCES_ARG=(--tileserver-instances "$RASTER_TILESERVER_INSTANCES")
  fi
  if [ -n "$RASTER_MAX_RENDERER_POOL_SIZES" ]; then
    MAX_RENDERER_POOL_SIZES_ARG=(--max-renderer-pool-sizes "$RASTER_MAX_RENDERER_POOL_SIZES")
  fi
  if [ -n "$RASTER_MIN_RENDERER_POOL_SIZES" ]; then
    MIN_RENDERER_POOL_SIZES_ARG=(--min-renderer-pool-sizes "$RASTER_MIN_RENDERER_POOL_SIZES")
  fi
  if [ -n "$RASTER_CONTOURS" ]; then
    CONTOURS_ARG=(--contours "$RASTER_CONTOURS")
  fi

  echo "[raster] Erzeuge $RASTER_OUTPUT aus $OUTPUT_MBTILES"
  "$PYTHON_BIN" "$SCRIPT_DIR/render_raster.py" \
    "$OUTPUT_MBTILES" \
    "$RASTER_OUTPUT" \
    --maxzoom "$RASTER_MAXZOOM" \
    --workers "$RASTER_WORKERS" \
    --format "$RASTER_FORMAT" \
    "${TILESERVER_INSTANCES_ARG[@]}" \
    "${MAX_RENDERER_POOL_SIZES_ARG[@]}" \
    "${MIN_RENDERER_POOL_SIZES_ARG[@]}" \
    "${CONTOURS_ARG[@]}"
fi

# Build Valhalla routing tiles
echo "[valhalla] Starte Valhalla-Tile-Generierung"
if [ -f "$SCRIPT_DIR/valhalla/build_valhalla_from_pbf.sh" ]; then
  bash "$SCRIPT_DIR/valhalla/build_valhalla_from_pbf.sh" \
    --input "$WORK_DIR/$PBF_FILE" \
    --output "$WORK_DIR" \
    --region "$REGION"
else
  echo "[warning] $SCRIPT_DIR/valhalla/build_valhalla_from_pbf.sh nicht gefunden"
fi
