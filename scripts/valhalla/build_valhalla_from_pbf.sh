#!/usr/bin/env bash
set -euo pipefail

# Build Valhalla routing data from a source .osm.pbf.
# Optional: clip a bounding box from a larger source extract first.
#
# Example:
#   ./scripts/valhalla/build_valhalla_from_pbf.sh \
#     --input ./tiles-germany/germany-latest.osm.pbf \
#     --output ./map/valhalla/output \
#     --region vogelsberg

INPUT_PBF=""
OUTPUT_DIR=""
BBOX=""
REGION="region"
VALHALLA_IMAGE="ghcr.io/gis-ops/docker-valhalla/valhalla:latest"

VOGELSBERG_BBOX="8.9,50.22,9.9,50.85"
BRAUNSCHWEIG_BBOX="10.28,52.12,10.78,52.42"

usage() {
  cat <<'EOF'
Usage:
  build_valhalla_from_pbf.sh --input <path.osm.pbf> --output <dir> [options]

Required:
  --input   Source .osm.pbf (for example germany-latest.osm.pbf)
  --output  Output directory for valhalla.json + data files

Optional:
  --bbox    west,south,east,north (WGS84), overrides region preset if provided
  --region  Region label used for intermediate files (default: region)
            Presets: vogelsberg -> 8.9,50.22,9.9,50.85
                     braunschweig -> 10.28,52.12,10.78,52.42
  --image   Docker image for Valhalla build
  --help    Show this help

Notes:
- If --bbox is provided, 'osmium' must be installed on the host.
- Build should run on a stronger machine; deploy output folder to Pi runtime.
EOF
}

resolve_region_bbox() {
  case "$1" in
    vogelsberg)
      printf '%s' "$VOGELSBERG_BBOX"
      ;;
    braunschweig)
      printf '%s' "$BRAUNSCHWEIG_BBOX"
      ;;
    *)
      return 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_PBF="$2"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --bbox)
      BBOX="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --image)
      VALHALLA_IMAGE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$INPUT_PBF" || -z "$OUTPUT_DIR" ]]; then
  echo "Error: --input and --output are required." >&2
  usage
  exit 1
fi

if [[ ! -f "$INPUT_PBF" ]]; then
  echo "Error: input file not found: $INPUT_PBF" >&2
  exit 1
fi

if [[ -z "$BBOX" ]]; then
  if PRESET_BBOX="$(resolve_region_bbox "$REGION" 2>/dev/null)"; then
    BBOX="$PRESET_BBOX"
    echo "[preset] Using bbox for region '$REGION': $BBOX"
  fi
elif resolve_region_bbox "$REGION" >/dev/null 2>&1; then
  echo "[preset] Ignoring preset bbox for region '$REGION' because --bbox was provided"
fi

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$OUTPUT_DIR/work"
mkdir -p "$WORK_DIR"

EXTRACT_PBF="$WORK_DIR/${REGION}.osm.pbf"

if [[ -n "$BBOX" ]]; then
  if ! command -v osmium >/dev/null 2>&1; then
    echo "Error: --bbox requires 'osmium' on PATH." >&2
    echo "Install osmium-tool and retry, or omit --bbox." >&2
    exit 1
  fi

  echo "[1/4] Creating bounded extract from $INPUT_PBF with bbox=$BBOX"
  osmium extract -b "$BBOX" "$INPUT_PBF" -o "$EXTRACT_PBF" --overwrite
else
  echo "[1/4] Using input extract directly"
  cp "$INPUT_PBF" "$EXTRACT_PBF"
fi

# Keep a root-level PBF so the GIS-OPS runtime image can auto-build if no prebuilt tiles exist.
cp "$EXTRACT_PBF" "$OUTPUT_DIR/${REGION}.osm.pbf"
mkdir -p "$OUTPUT_DIR/transit_tiles"

# Remove broken/stale config files. This image generates/updates valhalla.json itself.
if [[ -f "$OUTPUT_DIR/valhalla.json" && ! -s "$OUTPUT_DIR/valhalla.json" ]]; then
  rm -f "$OUTPUT_DIR/valhalla.json"
fi

if [[ -f "$OUTPUT_DIR/valhalla_tiles.tar" || -d "$OUTPUT_DIR/valhalla_tiles" ]]; then
  echo "[2/2] Prebuilt routing tiles already exist in $OUTPUT_DIR"
else
  echo "[2/2] Runtime input prepared. Start the container to let GIS-OPS build tiles from ${REGION}.osm.pbf"
fi

echo "Done"
echo "Prepared Valhalla runtime directory: $OUTPUT_DIR"
echo "Files in output: ${REGION}.osm.pbf, optional valhalla.json, optional valhalla_tiles.tar, admins.sqlite, timezones.sqlite"
