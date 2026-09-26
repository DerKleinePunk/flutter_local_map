#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 -d <data-dir> [-n <container-name>] [-i <docker-image>]"
    exit 1
}

DATA=""
NAME="valhalla-build"
IMAGE="ghcr.io/gis-ops/docker-valhalla/valhalla:latest"

while getopts ":d:n:i:" opt; do
    case $opt in
        d) DATA="$OPTARG" ;;
        n) NAME="$OPTARG" ;;
        i) IMAGE="$OPTARG" ;;
        *) usage ;;
    esac
done

if [[ -z "$DATA" ]]; then
    usage
fi

if [[ ! -d "$DATA" ]]; then
    echo "ERROR: Data directory not found: $DATA" >&2
    exit 1
fi

DATA_FULL="$(realpath "$DATA")"

# Container-Laufzeit wie in tilemaker.sh: docker nur, wenn es wirklich
# antwortet, sonst podman. Ueberschreibbar per CONTAINER_CMD.
CONTAINER_CMD="${CONTAINER_CMD:-}"
if [[ -z "$CONTAINER_CMD" ]]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        CONTAINER_CMD="docker"
    elif command -v podman >/dev/null 2>&1; then
        CONTAINER_CMD="podman"
    else
        echo "ERROR: Weder docker noch podman ist erreichbar." >&2
        exit 1
    fi
fi
echo "Container-Laufzeit: $CONTAINER_CMD"

# Voraussetzungen pruefen
if ! ls "$DATA_FULL"/*.osm.pbf &>/dev/null; then
    echo "ERROR: Keine .osm.pbf-Datei in $DATA_FULL gefunden. Tile-Build nicht moeglich." >&2
    exit 1
fi

TRANSIT_DIR="$DATA_FULL/transit_tiles"
mkdir -p "$TRANSIT_DIR"

CONFIG_PATH="$DATA_FULL/valhalla.json"
if [[ -f "$CONFIG_PATH" && ! -s "$CONFIG_PATH" ]]; then
    echo "Removing empty valhalla.json so the container can regenerate it"
    rm -f "$CONFIG_PATH"
fi

echo "Stopping leftover build container (if any): $NAME"
"$CONTAINER_CMD" rm -f "$NAME" 2>/dev/null || true

echo ""
echo "Pulling image: $IMAGE"
"$CONTAINER_CMD" pull "$IMAGE"

echo ""
echo "Starting Valhalla tile build from PBF in $DATA_FULL"
echo "(serve_tiles=False  ->  Container exits when build is done)"
echo ""

"$CONTAINER_CMD" run --rm \
    --name "$NAME" \
    -v "${DATA_FULL}:/custom_files" \
    -e use_tiles_ignore_pbf=False \
    -e force_rebuild=True \
    -e build_admins=True \
    -e build_time_zones=True \
    -e serve_tiles=False \
    "$IMAGE"

echo ""
echo "Tile build finished. Output in: $DATA_FULL"
echo "Starte jetzt den Server mit:"
echo "  ./scripts/valhalla/run_valhalla_server.sh -d \"$DATA\""
