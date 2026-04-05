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

# Vogelsberg: kleines Testgebiet in Hessen für schnelle Iterationen
VOGELSBERG_BBOX="8.9,50.35,9.9,50.85"

BBOX_ARG=()
if [ "${1:-}" = "vogelsberg" ]; then
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

if [ -f "$OUTPUT_MBTILES" ] && [ "${FORCE_REBUILD:-0}" != "1" ]; then
  echo "[skip] $OUTPUT_MBTILES existiert bereits."
  echo "       Setze FORCE_REBUILD=1, um die Datei neu zu erzeugen."
  exit 0
fi

if [ ! -f "$COASTLINE_DIR/water_polygons.shp" ] || [ ! -f "$COASTLINE_DIR/water_polygons.shx" ] || [ ! -f "$COASTLINE_DIR/water_polygons.dbf" ]; then
  echo "[error] Fehlende Shapefile-Bestandteile in $COASTLINE_DIR"
  echo "        Erwartet: water_polygons.shp, water_polygons.shx, water_polygons.dbf"
  exit 1
fi

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
    "${BBOX_ARG[@]:-}" \
    --store /data/temp
