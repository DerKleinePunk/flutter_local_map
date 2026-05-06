#!/usr/bin/env bash
# build_contours.sh – Höhenlinien-MBTiles aus Copernicus-DEM erzeugen
#
# Pipeline:
#   1. Copernicus DEM 30 m (GLO-30) per GDAL /vsicurl/ herunterladen und clippen
#   2. gdal_contour  → GeoPackage mit 10-m- und 50-m-Linien
#   3. ogr2ogr       → GeoJSON (tippecanoe-Eingabe)
#   4. tippecanoe    → Vektor-MBTiles
#
# Voraussetzung: Docker muss laufen.
#
# Nutzung:
#   ./build_contours.sh [vogelsberg|braunschweig|germany]
#
# Umgebungsvariablen:
#   CONTOUR_INTERVAL    Hauptintervall in Metern (default: 10)
#   CONTOUR_MINZOOM     Tippecanoe Minzoom          (default: 9)
#   CONTOUR_MAXZOOM     Tippecanoe Maxzoom          (default: 14)
#   FORCE_REBUILD       =1 um vorhandene Datei neu zu erzeugen

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
WORK_DIR="$PROJECT_ROOT/map/tiles-germany"

mkdir -p "$WORK_DIR"

# ---------------------------------------------------------------------------
# Regionen (identisch zu tilemaker.sh)
# ---------------------------------------------------------------------------
VOGELSBERG_BBOX="8.9,50.22,9.9,50.85"
BRAUNSCHWEIG_BBOX="10.28,52.12,10.78,52.42"
# Deutschland – größere BBox damit Rand-Tiles vollständig sind
GERMANY_BBOX="5.8,47.2,15.1,55.1"

REGION="vogelsberg"

show_usage() {
  echo "Nutzung: ./build_contours.sh [vogelsberg|braunschweig|germany]"
  echo ""
  echo "  vogelsberg   (default)  Testgebiet Fulda/Vogelsberg"
  echo "  braunschweig            Braunschweig mit Umland"
  echo "  germany                 Ganz Deutschland (langsam, ~mehrere GB DEM)"
  echo ""
  echo "Optionale Umgebungsvariablen:"
  echo "  CONTOUR_INTERVAL   Höhenlinien-Abstand in Metern (default: 10)"
  echo "  CONTOUR_MINZOOM    Tippecanoe Minzoom             (default: 9)"
  echo "  CONTOUR_MAXZOOM    Tippecanoe Maxzoom             (default: 14)"
  echo "  FORCE_REBUILD=1    Vorhandene Dateien neu erzeugen"
}

for arg in "$@"; do
  case "$arg" in
    vogelsberg)   REGION="vogelsberg" ;;
    braunschweig) REGION="braunschweig" ;;
    germany)      REGION="germany" ;;
    -h|--help) show_usage; exit 0 ;;
    *)
      echo "[error] Unbekannter Parameter: $arg"
      show_usage
      exit 1
      ;;
  esac
done

case "$REGION" in
  vogelsberg)   BBOX="$VOGELSBERG_BBOX" ;;
  braunschweig) BBOX="$BRAUNSCHWEIG_BBOX" ;;
  germany)      BBOX="$GERMANY_BBOX" ;;
esac

CONTOUR_INTERVAL="${CONTOUR_INTERVAL:-10}"
CONTOUR_MINZOOM="${CONTOUR_MINZOOM:-9}"
CONTOUR_MAXZOOM="${CONTOUR_MAXZOOM:-14}"

OUTPUT_MBTILES="$WORK_DIR/${REGION}_contours.mbtiles"
DEM_TIF="$WORK_DIR/${REGION}_dem.tif"
CONTOUR_GPKG="$WORK_DIR/${REGION}_contours.gpkg"
CONTOUR_GEOJSON="$WORK_DIR/${REGION}_contours.geojson"

has_valid_raster_pixels() {
  local raster_path="$1"
  docker run --rm \
    -v "$WORK_DIR:/data" \
    "$GDAL_IMAGE" \
    gdalinfo -stats "/data/$(basename "$raster_path")" 2>/dev/null | grep -q 'STATISTICS_VALID_PERCENT=[1-9]'
}

has_vector_features() {
  local vector_path="$1"
  docker run --rm \
    -v "$WORK_DIR:/data" \
    "$GDAL_IMAGE" \
    ogrinfo -so "/data/$(basename "$vector_path")" 2>/dev/null | grep -Eq 'Feature Count: [1-9]'
}

# BBox-Teile für GDAL: west,south,east,north → -projwin west north east south
IFS=',' read -r BBOX_WEST BBOX_SOUTH BBOX_EAST BBOX_NORTH <<< "$BBOX"

echo "[info] Region:   $REGION"
echo "[info] BBox:     $BBOX"
echo "[info] Interval: ${CONTOUR_INTERVAL} m"
echo "[info] Zoom:     z${CONTOUR_MINZOOM}–z${CONTOUR_MAXZOOM}"
echo "[info] Ausgabe:  $OUTPUT_MBTILES"

GDAL_IMAGE="ghcr.io/osgeo/gdal:ubuntu-small-latest"
TIPPECANOE_IMAGE="klokantech/tippecanoe:latest"

if [ "${FORCE_REBUILD:-0}" = "1" ]; then
  echo "[rebuild] FORCE_REBUILD=1 gesetzt, entferne Zwischenprodukte"
  rm -f "$DEM_TIF" "$DEM_TIF.aux.xml" "$CONTOUR_GPKG" "$CONTOUR_GEOJSON" "$OUTPUT_MBTILES"
  rm -rf "$WORK_DIR/dem_tiles/$REGION"
fi

# ---------------------------------------------------------------------------
# Schritt 1 – DEM kachelweise herunterladen und zusammenfügen
# ---------------------------------------------------------------------------
# Quelle: elevation-tiles-prod (AWS, öffentlich, kein Auth):
#   https://s3.amazonaws.com/elevation-tiles-prod/geotiff/{z}/{x}/{y}.tif
# GeoTIFF-Tiles mit echten Höhenwerten in Metern (SRTM + Copernicus merged).
# Zoom 12 ≈ 40 m/px – ausreichend fuer 10-m-Konturlinien auf den Zielzoomleveln.
DEM_ZOOM=12
DEM_BASE="https://s3.amazonaws.com/elevation-tiles-prod/geotiff/$DEM_ZOOM"
DEM_TILES_DIR="$WORK_DIR/dem_tiles/$REGION/z$DEM_ZOOM"

if [ -f "$DEM_TIF" ] && [ "${FORCE_REBUILD:-0}" != "1" ]; then
  if has_valid_raster_pixels "$DEM_TIF"; then
    echo "[skip] DEM bereits vorhanden: $DEM_TIF"
  else
    echo "[dem] Vorhandenes DEM ist ungueltig, erzeuge neu: $DEM_TIF"
    rm -f "$DEM_TIF"
  fi
fi

if [ ! -f "$DEM_TIF" ]; then
  rm -rf "$DEM_TILES_DIR"
  mkdir -p "$DEM_TILES_DIR"

  # XYZ-Tile-Koordinaten aus WGS84-BBox berechnen
  _lon2x() {
    python3 - "$1" "$2" <<'PY'
import sys
lon = float(sys.argv[1])
zoom = int(sys.argv[2])
print(int((lon + 180.0) / 360.0 * (2 ** zoom)))
PY
  }
  _lat2y() {
    python3 - "$1" "$2" <<'PY'
import math
import sys

lat = float(sys.argv[1])
zoom = int(sys.argv[2])
lat_r = math.radians(lat)
y = int((1.0 - math.log(math.tan(lat_r) + 1.0 / math.cos(lat_r)) / math.pi) / 2.0 * (2 ** zoom))
print(y)
PY
  }

  TILE_X_MIN=$(_lon2x "$BBOX_WEST"  "$DEM_ZOOM")
  TILE_X_MAX=$(_lon2x "$BBOX_EAST"  "$DEM_ZOOM")
  TILE_Y_MIN=$(_lat2y "$BBOX_NORTH" "$DEM_ZOOM")   # Nord → kleinere Y-Zahl
  TILE_Y_MAX=$(_lat2y "$BBOX_SOUTH" "$DEM_ZOOM")   # Süd  → größere Y-Zahl

  TILE_FILES=()
  for x in $(seq "$TILE_X_MIN" "$TILE_X_MAX"); do
    for y in $(seq "$TILE_Y_MIN" "$TILE_Y_MAX"); do
      tile_url="${DEM_BASE}/${x}/${y}.tif"
      tile_file="$DEM_TILES_DIR/dem_z${DEM_ZOOM}_${x}_${y}.tif"

      if [ -f "$tile_file" ]; then
        echo "[skip] Kachel bereits vorhanden: $(basename "$tile_file")"
      else
        echo "[dem] Lade Kachel z${DEM_ZOOM}/${x}/${y}"
        if wget -q --show-progress -O "$tile_file" "$tile_url"; then
          echo "[ok] Kachel: $(basename "$tile_file")"
        else
          echo "[warn] Kachel nicht verfuegbar: z${DEM_ZOOM}/${x}/${y}"
          rm -f "$tile_file"
        fi
      fi

      [ -f "$tile_file" ] && TILE_FILES+=("/data/dem_tiles/$REGION/z$DEM_ZOOM/$(basename "$tile_file")")
    done
  done

  if [ "${#TILE_FILES[@]}" -eq 0 ]; then
    echo "[error] Keine DEM-Kacheln gefunden fuer BBox $BBOX"
    exit 1
  fi

  echo "[dem] Fuege ${#TILE_FILES[@]} Kachel(n) zusammen und clippe auf BBox ..."

  # VRT aus Kacheln bauen und auf BBox clippen – alles in einem Docker-Aufruf
  docker run --rm \
    -v "$WORK_DIR:/data" \
    "$GDAL_IMAGE" \
    bash -c "
      gdalbuildvrt /tmp/dem_merged.vrt ${TILE_FILES[*]} && \
      gdal_translate \
        -projwin $BBOX_WEST $BBOX_NORTH $BBOX_EAST $BBOX_SOUTH \
        -projwin_srs EPSG:4326 \
        -of GTiff \
        -co COMPRESS=LZW \
        -co TILED=YES \
        /tmp/dem_merged.vrt \
        /data/$(basename "$DEM_TIF")
    "
  echo "[ok] DEM: $DEM_TIF"
fi

# ---------------------------------------------------------------------------
# Schritt 2 – Konturlinien erzeugen (gdal_contour)
# ---------------------------------------------------------------------------
if [ -f "$CONTOUR_GPKG" ] && [ "${FORCE_REBUILD:-0}" != "1" ]; then
  if has_vector_features "$CONTOUR_GPKG"; then
    echo "[skip] Kontur-GeoPackage bereits vorhanden: $CONTOUR_GPKG"
  else
    echo "[contour] Vorhandenes GeoPackage ist leer, erzeuge neu: $CONTOUR_GPKG"
    rm -f "$CONTOUR_GPKG"
  fi
fi

if [ ! -f "$CONTOUR_GPKG" ]; then
  echo "[contour] Erzeuge Höhenlinien alle ${CONTOUR_INTERVAL} m ..."
  docker run --rm \
    -v "$WORK_DIR:/data" \
    "$GDAL_IMAGE" \
    gdal_contour \
      -a ele \
      -i "$CONTOUR_INTERVAL" \
      -f GPKG \
      /data/"$(basename "$DEM_TIF")" \
      /data/"$(basename "$CONTOUR_GPKG")"
  echo "[ok] Kontur-GeoPackage: $CONTOUR_GPKG"
fi

# ---------------------------------------------------------------------------
# Schritt 3 – GeoPackage → GeoJSON (tippecanoe-Eingabe)
# ---------------------------------------------------------------------------
if [ -f "$CONTOUR_GEOJSON" ] && [ "${FORCE_REBUILD:-0}" != "1" ]; then
  if python3 - <<'PY' "$CONTOUR_GEOJSON"
import json, sys
path = sys.argv[1]
with open(path, encoding='utf-8') as fh:
    data = json.load(fh)
features = data.get('features', [])
sys.exit(0 if features else 1)
PY
  then
    echo "[skip] GeoJSON bereits vorhanden: $CONTOUR_GEOJSON"
  else
    echo "[convert] Vorhandenes GeoJSON ist leer, erzeuge neu: $CONTOUR_GEOJSON"
    rm -f "$CONTOUR_GEOJSON"
  fi
fi

if [ ! -f "$CONTOUR_GEOJSON" ]; then
  echo "[convert] Konvertiere GeoPackage → GeoJSON ..."
  docker run --rm \
    -v "$WORK_DIR:/data" \
    "$GDAL_IMAGE" \
    ogr2ogr \
      -f GeoJSON \
      -t_srs EPSG:4326 \
      /data/"$(basename "$CONTOUR_GEOJSON")" \
      /data/"$(basename "$CONTOUR_GPKG")"
  echo "[ok] GeoJSON: $CONTOUR_GEOJSON"
fi

# ---------------------------------------------------------------------------
# Schritt 4 – GeoJSON → Vektor-MBTiles (tippecanoe)
# ---------------------------------------------------------------------------
if [ -f "$OUTPUT_MBTILES" ] && [ "${FORCE_REBUILD:-0}" != "1" ]; then
  echo "[skip] MBTiles bereits vorhanden: $OUTPUT_MBTILES"
  echo "       Setze FORCE_REBUILD=1, um neu zu erzeugen."
else
  if [ -f "$OUTPUT_MBTILES" ]; then
    echo "[rebuild] Entferne vorhandene Datei: $OUTPUT_MBTILES"
    rm -f "$OUTPUT_MBTILES"
  fi

  echo "[tippecanoe] Erzeuge Vektor-MBTiles z${CONTOUR_MINZOOM}–z${CONTOUR_MAXZOOM} ..."
  docker run --rm \
    -v "$WORK_DIR:/data" \
    "$TIPPECANOE_IMAGE" \
    tippecanoe \
      --output=/data/"$(basename "$OUTPUT_MBTILES")" \
      --layer=contour \
      --minimum-zoom="$CONTOUR_MINZOOM" \
      --maximum-zoom="$CONTOUR_MAXZOOM" \
      --simplification=2 \
      --drop-densest-as-needed \
      --extend-zooms-if-still-dropping \
      --no-tile-compression \
      --force \
      /data/"$(basename "$CONTOUR_GEOJSON")"
  echo "[ok] MBTiles: $OUTPUT_MBTILES"
fi

echo ""
echo "[done] Konturlinien fertig: $(basename "$OUTPUT_MBTILES")"
echo "       Fuer Raster-Rendering:"
echo "       RASTER_CONTOURS=$(basename "$OUTPUT_MBTILES") ./scripts/tilemaker.sh $REGION raster"
