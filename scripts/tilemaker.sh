#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$PROJECT_ROOT/map/tiles-germany"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

PBF_FILE="germany-latest.osm.pbf"
WATER_ZIP="water-polygons-split-4326.zip"
COASTLINE_DIR="coastline"

show_usage() {
  echo "Nutzung: ./tilemaker.sh [vogelsberg] [raster|--raster]"
  echo ""
  echo "  ohne Parameter:    Germany Vector-MBTiles"
  echo "  vogelsberg:        kleines Testgebiet (BBox)"
  echo "  raster|--raster:   zusaetzlich Raster-MBTiles aus Vektor-MBTiles erzeugen"
  echo ""
  echo "Optionale Umgebungsvariablen fuer Raster-Schritt:"
  echo "  RASTER_MAXZOOM (default: 17)"
  echo "  RASTER_WORKERS (default: 4)"
}

# Vogelsberg: kleines Testgebiet in Hessen für schnelle Iterationen
VOGELSBERG_BBOX="8.9,50.35,9.9,50.85"

BBOX_ARG=()
GENERATE_RASTER=0
REGION="germany"

for arg in "$@"; do
  case "$arg" in
    vogelsberg)
      REGION="vogelsberg"
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

if [ "$REGION" = "vogelsberg" ]; then
  echo "[bbox] Vogelsberg-Testgebiet: $VOGELSBERG_BBOX"
  BBOX_ARG+=(--bbox "$VOGELSBERG_BBOX")
  OUTPUT_MBTILES="vogelsberg.mbtiles"
else
  OUTPUT_MBTILES="germany.mbtiles"
fi

# Deutschland PBF (~4 GB)
if [ -f "$PBF_FILE" ]; then
  echo "[skip] $PBF_FILE ist bereits vorhanden"
else
  echo "[download] Lade $PBF_FILE herunter"
  wget -O "$PBF_FILE" https://download.geofabrik.de/europe/germany-latest.osm.pbf
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

  docker run -it --rm --pull always \
    -w /data \
    -v "$WORK_DIR:/data" \
    -v "$PROJECT_ROOT:/workspace" \
    ghcr.io/systemed/tilemaker:master \
      --input /data/$PBF_FILE \
      --output /data/$OUTPUT_MBTILES \
      --config /workspace/scripts/tilemaker/config-openmaptiles-z17.json \
      --process /usr/src/app/resources/process-openmaptiles.lua \
      "${TILEMAKER_REBUILD_ARG[@]}" \
      "${BBOX_ARG[@]}" \
      --store /data/temp
fi

# Extract searchable names database
NAMES_DB_OUTPUT="${OUTPUT_MBTILES%.mbtiles}_names.db"
if [ -f "$NAMES_DB_OUTPUT" ]; then
  echo "[skip] $NAMES_DB_OUTPUT existiert bereits"
else
  PYTHON_BIN="python3"
  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    PYTHON_BIN="python"
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
  RASTER_WORKERS="${RASTER_WORKERS:-4}"

  PYTHON_BIN="python3"
  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    PYTHON_BIN="python"
  fi

  echo "[raster] Erzeuge $RASTER_OUTPUT aus $OUTPUT_MBTILES"
  "$PYTHON_BIN" "$SCRIPT_DIR/render_raster.py" \
    "$OUTPUT_MBTILES" \
    "$RASTER_OUTPUT" \
    --maxzoom "$RASTER_MAXZOOM" \
    --workers "$RASTER_WORKERS"
fi
