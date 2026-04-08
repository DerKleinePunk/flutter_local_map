#!/usr/bin/env bash
set -euo pipefail

# Run local Valhalla server from prepared data directory.
#
# Example:
#   ./scripts/valhalla/run_valhalla_server.sh --data ./map/valhalla/output --port 8002

DATA_DIR=""
PORT="8002"
VALHALLA_IMAGE="ghcr.io/gis-ops/docker-valhalla/valhalla:latest"
CONTAINER_NAME="valhalla-local"

usage() {
  cat <<'EOF'
Usage:
  run_valhalla_server.sh --data <dir> [options]

Required:
  --data   Directory containing valhalla.json and data files

Optional:
  --port   Host port (default: 8002)
  --name   Docker container name (default: valhalla-local)
  --image  Docker image (default: ghcr.io/gis-ops/docker-valhalla/valhalla:latest)
  --help   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data)
      DATA_DIR="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --name)
      CONTAINER_NAME="$2"
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

if [[ -z "$DATA_DIR" ]]; then
  echo "Error: --data is required." >&2
  usage
  exit 1
fi

mkdir -p "$DATA_DIR/transit_tiles"

if [[ -f "$DATA_DIR/valhalla.json" && ! -s "$DATA_DIR/valhalla.json" ]]; then
  echo "Removing empty valhalla.json so the container can regenerate it"
  rm -f "$DATA_DIR/valhalla.json"
fi

echo "Stopping existing container (if any): $CONTAINER_NAME"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

USE_TILES_IGNORE_PBF="False"
FORCE_REBUILD="False"
BUILD_ADMINS="True"
BUILD_TIME_ZONES="True"

if [[ -f "$DATA_DIR/valhalla_tiles.tar" || -d "$DATA_DIR/valhalla_tiles" ]]; then
  USE_TILES_IGNORE_PBF="True"
  FORCE_REBUILD="False"
else
  if ls "$DATA_DIR"/*.osm.pbf >/dev/null 2>&1; then
    USE_TILES_IGNORE_PBF="False"
    FORCE_REBUILD="True"
  else
    echo "Error: Weder prebuilt tiles noch .osm.pbf in $DATA_DIR gefunden." >&2
    echo "Lege entweder valhalla_tiles.tar ab oder ein .osm.pbf direkt im DATA_DIR." >&2
    exit 1
  fi
fi

echo "Starting Valhalla on http://127.0.0.1:$PORT"
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "$PORT:8002" \
  -v "$(realpath "$DATA_DIR"):/custom_files" \
  -e use_tiles_ignore_pbf="$USE_TILES_IGNORE_PBF" \
  -e force_rebuild="$FORCE_REBUILD" \
  -e build_admins="$BUILD_ADMINS" \
  -e build_time_zones="$BUILD_TIME_ZONES" \
  -e serve_tiles=True \
  "$VALHALLA_IMAGE"

echo "Container started: $CONTAINER_NAME"
echo "Test with: curl -X POST http://127.0.0.1:$PORT/route -H 'Content-Type: application/json' -d '{\"locations\":[{\"lat\":50.55,\"lon\":9.68},{\"lat\":50.56,\"lon\":9.70}],\"costing\":\"auto\"}'"
