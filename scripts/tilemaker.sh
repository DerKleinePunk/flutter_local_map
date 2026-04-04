#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$PROJECT_ROOT/map/tiles-germany"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

PBF_FILE="germany-latest.osm.pbf"
WATER_ZIP="water-polygons-split-4326.zip"
COASTLINE_DIR="coastline"
OUTPUT_MBTILES="germany.mbtiles"

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

if [ -f "$OUTPUT_MBTILES" ] && [ "${FORCE_REBUILD:-0}" != "1" ]; then
  echo "[skip] $OUTPUT_MBTILES existiert bereits."
  echo "       Setze FORCE_REBUILD=1, um die Datei neu zu erzeugen."
  exit 0
fi

docker run -it --rm --pull always \
  -v "$WORK_DIR:/data" \
  -v "$PROJECT_ROOT:/workspace" \
  ghcr.io/systemed/tilemaker:master \
    --input /data/$PBF_FILE \
    --output /data/$OUTPUT_MBTILES \
    --config /workspace/scripts/tilemaker/config-openmaptiles-z16.json \
    --process /usr/src/app/resources/process-openmaptiles.lua
