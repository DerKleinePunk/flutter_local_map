#!/usr/bin/env bash
# build_contours.sh – Höhenlinien-MBTiles aus den Terrain Tiles erzeugen
#
# Pipeline:
#   1. Höhenkacheln aus elevation-tiles-prod (Terrain Tiles von tilezen/joerd,
#      GeoTIFF z12, etwa 40 m) laden, zusammenfügen, auf BBox bzw. Grenze
#      zuschneiden. Quellenvermerk: MapConfig.elevationAttribution* in local_map.
#   2. gdal_contour  → GeoPackage mit Linien alle CONTOUR_INTERVAL m (10)
#   3. ogr2ogr       → GeoJSONSeq (tippecanoe-Eingabe), Nebenlinien erst ab z13
#   4. tippecanoe    → Vektor-MBTiles
#
# Voraussetzung: docker oder podman (Auswahl wie in tilemaker.sh).
#
# Nutzung:
#   ./build_contours.sh [vogelsberg|braunschweig|germany|dach]
#
# Umgebungsvariablen:
#   CONTOUR_INTERVAL    Hauptintervall in Metern (default: 10)
#   CONTOUR_MINZOOM     Tippecanoe Minzoom          (default: 11)
#   CONTOUR_MAJOR       Abstand der Hauptlinien in m (default: 50)
#   CONTOUR_MINOR_MINZOOM  ab diesem Zoom alle Linien, darunter nur die
#                       Hauptlinien (default: 13)
#   CONTOUR_MAXZOOM     Tippecanoe Maxzoom          (default: 14)
#   FORCE_REBUILD       =1 um vorhandene Datei neu zu erzeugen
#   DEM_PARALLEL        gleichzeitige Downloads der Hoehenkacheln (default: 8)
#   CONTOURS_WORK_DIR   Arbeitsverzeichnis (default: TILEMAKER_WORK_DIR bzw.
#                       map/tiles-germany). Bei podman-remote muss es unter
#                       /mnt/wsl liegen, etwa /mnt/wsl/code/tiles-germany.
#   CONTAINER_CMD       docker|podman|<pfad>; sonst automatisch

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
WORK_DIR="${CONTOURS_WORK_DIR:-${TILEMAKER_WORK_DIR:-$PROJECT_ROOT/map/tiles-germany}}"

mkdir -p "$WORK_DIR"

# Container-Laufzeit wie in tilemaker.sh: `command -v docker` reicht unter WSL
# nicht, deshalb zusaetzlich `docker info`.
CONTAINER_CMD="${CONTAINER_CMD:-}"
if [ -z "$CONTAINER_CMD" ]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
  elif command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
  else
    echo "[error] Weder docker noch podman ist erreichbar (CONTAINER_CMD setzen)."
    exit 1
  fi
fi
echo "[container] Laufzeit: $CONTAINER_CMD"

# ---------------------------------------------------------------------------
# Regionen (identisch zu tilemaker.sh)
# ---------------------------------------------------------------------------
VOGELSBERG_BBOX="8.9,50.22,9.9,50.85"
BRAUNSCHWEIG_BBOX="10.28,52.12,10.78,52.42"
# Deutschland – größere BBox damit Rand-Tiles vollständig sind
GERMANY_BBOX="5.8,47.2,15.1,55.1"
# DACH folgt der Grenze aus Geofabriks dach.poly statt einem Rechteck: das
# Rechteck enthielte halb Tschechien, Norditalien und Westungarn (22 270 statt
# 13 851 Hoehenkacheln), und die Alpen dort kosten die meisten Linien.
DACH_POLY_URL="https://download.geofabrik.de/europe/dach/dach.poly"

REGION="vogelsberg"

show_usage() {
  echo "Nutzung: ./build_contours.sh [vogelsberg|braunschweig|germany]"
  echo ""
  echo "  vogelsberg   (default)  Testgebiet Fulda/Vogelsberg"
  echo "  braunschweig            Braunschweig mit Umland"
  echo "  germany                 Ganz Deutschland (langsam, ~mehrere GB DEM)"
  echo "  dach                    Deutschland, Oesterreich, Schweiz entlang der Grenze"
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
    dach)         REGION="dach" ;;
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

POLY_FILE=""
if [ "$REGION" = "dach" ]; then
  POLY_FILE="$WORK_DIR/dach.poly"
  if [ ! -s "$POLY_FILE" ]; then
    echo "[poly] Lade $DACH_POLY_URL"
    curl -sSfL -o "$POLY_FILE" "$DACH_POLY_URL" || { echo "[error] dach.poly nicht ladbar"; exit 1; }
  fi
  BBOX="$(python3 "$SCRIPT_DIR/contours_tiles.py" bbox "$POLY_FILE")"
fi
DEM_PARALLEL="${DEM_PARALLEL:-8}"

CONTOUR_INTERVAL="${CONTOUR_INTERVAL:-10}"
# Der Navigations-Style von local_map zeichnet Hoehenlinien erst ab z11 und
# bis z12 nur die Hauptlinien. Was darunter oder dazwischen in den Kacheln
# laege, wuerde auf dem Pi trotzdem geladen und dekodiert.
CONTOUR_MINZOOM="${CONTOUR_MINZOOM:-11}"
CONTOUR_MAJOR="${CONTOUR_MAJOR:-50}"
CONTOUR_MINOR_MINZOOM="${CONTOUR_MINOR_MINZOOM:-13}"
CONTOUR_MAXZOOM="${CONTOUR_MAXZOOM:-14}"

OUTPUT_MBTILES="$WORK_DIR/${REGION}_contours.mbtiles"
DEM_TIF="$WORK_DIR/${REGION}_dem.tif"
CONTOUR_GPKG="$WORK_DIR/${REGION}_contours.gpkg"
CONTOUR_GEOJSON="$WORK_DIR/${REGION}_contours.geojsonseq"

has_valid_raster_pixels() {
  local raster_path="$1"
  "$CONTAINER_CMD" run --rm \
    -v "$WORK_DIR:/data" \
    "$GDAL_IMAGE" \
    gdalinfo -stats "/data/$(basename "$raster_path")" 2>/dev/null | grep -q 'STATISTICS_VALID_PERCENT=[1-9]'
}

has_vector_features() {
  local vector_path="$1"
  "$CONTAINER_CMD" run --rm \
    -v "$WORK_DIR:/data" \
    "$GDAL_IMAGE" \
    ogrinfo -so -al "/data/$(basename "$vector_path")" 2>/dev/null | grep -Eq 'Feature Count: [1-9]'
}

# BBox-Teile für GDAL: west,south,east,north → -projwin west north east south
IFS=',' read -r BBOX_WEST BBOX_SOUTH BBOX_EAST BBOX_NORTH <<< "$BBOX"

echo "[info] Region:   $REGION"
echo "[info] BBox:     $BBOX"
echo "[info] Interval: ${CONTOUR_INTERVAL} m"
echo "[info] Zoom:     z${CONTOUR_MINZOOM}–z${CONTOUR_MAXZOOM} (alle Linien ab z${CONTOUR_MINOR_MINZOOM}, darunter nur alle ${CONTOUR_MAJOR} m)"
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
  # Vorhandene Kacheln bleiben liegen: ein abgebrochener Lauf (DACH: ~14 000
  # Kacheln) laedt beim naechsten Mal nur, was fehlt.
  mkdir -p "$DEM_TILES_DIR"
  TILE_LIST="$WORK_DIR/dem_tiles/$REGION/tiles-z$DEM_ZOOM.txt"
  if [ -n "$POLY_FILE" ]; then
    python3 "$SCRIPT_DIR/contours_tiles.py" tiles "$DEM_ZOOM" --poly "$POLY_FILE" > "$TILE_LIST"
  else
    python3 "$SCRIPT_DIR/contours_tiles.py" tiles "$DEM_ZOOM" --bbox "$BBOX" > "$TILE_LIST"
  fi
  echo "[dem] $(wc -l < "$TILE_LIST") Kachel(n) fuer $REGION, lade fehlende (${DEM_PARALLEL} parallel) ..."

  # Je Kachel ein wget; was es nicht gibt (Meer), bleibt einfach weg.
  xargs -P "$DEM_PARALLEL" -n 2 sh -c '
        f="'"$DEM_TILES_DIR"'/dem_z'"$DEM_ZOOM"'_$0_$1.tif"
        [ -s "$f" ] && exit 0
        wget -q -O "$f.part" "'"$DEM_BASE"'/$0/$1.tif" && mv "$f.part" "$f" || rm -f "$f.part"
      ' < "$TILE_LIST"

  FILE_LIST="$WORK_DIR/dem_tiles/$REGION/files-z$DEM_ZOOM.txt"
  : > "$FILE_LIST"
  missing=0
  while read -r x y; do
    if [ -s "$DEM_TILES_DIR/dem_z${DEM_ZOOM}_${x}_${y}.tif" ]; then
      echo "/data/dem_tiles/$REGION/z$DEM_ZOOM/dem_z${DEM_ZOOM}_${x}_${y}.tif" >> "$FILE_LIST"
    else
      missing=$((missing + 1))
    fi
  done < "$TILE_LIST"
  echo "[dem] $(wc -l < "$FILE_LIST") vorhanden, $missing nicht verfuegbar"

  if [ ! -s "$FILE_LIST" ]; then
    echo "[error] Keine DEM-Kacheln gefunden fuer $REGION"
    exit 1
  fi

  if [ -n "$POLY_FILE" ]; then
    python3 "$SCRIPT_DIR/contours_tiles.py" geojson "$POLY_FILE" "$WORK_DIR/${REGION}_grenze.geojson"
    echo "[dem] Fuege zusammen und schneide an der Grenze zu ($(basename "$POLY_FILE")) ..."
    CUT_CMD="gdalwarp -cutline /data/${REGION}_grenze.geojson -crop_to_cutline -dstnodata -32768 \
      -co COMPRESS=LZW -co TILED=YES -co BIGTIFF=YES -multi -wo NUM_THREADS=ALL_CPUS \
      /tmp/dem_merged.vrt /data/$(basename "$DEM_TIF")"
  else
    echo "[dem] Fuege zusammen und clippe auf BBox ..."
    CUT_CMD="gdal_translate -projwin $BBOX_WEST $BBOX_NORTH $BBOX_EAST $BBOX_SOUTH \
      -projwin_srs EPSG:4326 -of GTiff -co COMPRESS=LZW -co TILED=YES -co BIGTIFF=IF_SAFER \
      /tmp/dem_merged.vrt /data/$(basename "$DEM_TIF")"
  fi
  "$CONTAINER_CMD" run --rm \
    -v "$WORK_DIR:/data" \
    "$GDAL_IMAGE" \
    bash -c "gdalbuildvrt -input_file_list /data/dem_tiles/$REGION/files-z$DEM_ZOOM.txt /tmp/dem_merged.vrt && $CUT_CMD"
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
  "$CONTAINER_CMD" run --rm \
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
# Schritt 3 – GeoPackage → GeoJSONSeq (tippecanoe-Eingabe)
# ---------------------------------------------------------------------------
# Eine Linie pro Zeile. Jede bekommt `major` (1 = Hauptlinie), Nebenlinien
# zusaetzlich "tippecanoe":{"minzoom":...}: tippecanoe 1.24 kennt `$zoom` in
# Filtern (-j) noch nicht, die Mindestzoomstufe je Linie aber schon.
if [ -f "$CONTOUR_GEOJSON" ] && [ "${FORCE_REBUILD:-0}" != "1" ]; then
  if head -n 1 "$CONTOUR_GEOJSON" | grep -q '"major":'; then
    echo "[skip] GeoJSONSeq bereits vorhanden: $CONTOUR_GEOJSON"
  else
    echo "[convert] Vorhandenes GeoJSONSeq ist leer oder alt, erzeuge neu: $CONTOUR_GEOJSON"
    rm -f "$CONTOUR_GEOJSON"
  fi
fi

if [ ! -f "$CONTOUR_GEOJSON" ]; then
  echo "[convert] Konvertiere GeoPackage → GeoJSONSeq ..."
  "$CONTAINER_CMD" run --rm \
    -v "$WORK_DIR:/data" \
    -e MAJOR="$CONTOUR_MAJOR" \
    -e MINOR_MINZOOM="$CONTOUR_MINOR_MINZOOM" \
    -e GPKG="/data/$(basename "$CONTOUR_GPKG")" \
    -e OUT="/data/$(basename "$CONTOUR_GEOJSON")" \
    "$GDAL_IMAGE" \
    bash -c 'set -o pipefail
      ogr2ogr -f GeoJSONSeq -t_srs EPSG:4326 -dialect SQLite \
        -sql "SELECT *, CASE WHEN CAST(ele AS INTEGER) % $MAJOR = 0 THEN 1 ELSE 0 END AS major FROM contour" \
        /vsistdout/ "$GPKG" \
      | sed -E "s/^\{\"type\":\"Feature\",(\"properties\":\{[^}]*\"major\":0\})/{\"type\":\"Feature\",\"tippecanoe\":{\"minzoom\":$MINOR_MINZOOM},\1/" \
      > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"'
  echo "[ok] GeoJSONSeq: $CONTOUR_GEOJSON"
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

  # Kacheln gzip-gepackt (tippecanoe-Vorgabe) wie in der Hauptkarte: local_map
  # liest jede Vektorquelle mit gzip, MapLibre fuer den Raster-Bau kann beides.
  echo "[tippecanoe] Erzeuge Vektor-MBTiles z${CONTOUR_MINZOOM}–z${CONTOUR_MAXZOOM} ..."
  "$CONTAINER_CMD" run --rm \
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
      --force \
      /data/"$(basename "$CONTOUR_GEOJSON")"
  echo "[ok] MBTiles: $OUTPUT_MBTILES"
fi

echo ""
echo "[done] Konturlinien fertig: $(basename "$OUTPUT_MBTILES")"
echo "       Fuer Raster-Rendering:"
echo "       RASTER_CONTOURS=$(basename "$OUTPUT_MBTILES") ./scripts/tilemaker.sh $REGION raster"
