#!/usr/bin/env bash
set -euo pipefail

# Deploy prebuilt Valhalla binaries and optional routing data to Raspberry Pi.
#
# Example:
#   ./scripts/valhalla/deploy_valhalla_pi.sh \
#     --host 192.168.2.50 --user pi \
#     --archive ./map/valhalla/valhalla-aarch64.tar.gz \
#     --target /opt/valhalla \
#     --data ./map/valhalla/output

PI_HOST=""
PI_USER=""
PI_PORT="22"
ARCHIVE_PATH=""
TARGET_DIR="/opt/valhalla"
DATA_DIR=""

usage() {
  cat <<'EOF'
Usage:
  deploy_valhalla_pi.sh --host <ip-or-host> --user <ssh-user> --archive <valhalla-aarch64.tar.gz> [options]

Required:
  --host     Raspberry Pi host/IP
  --user     SSH user
  --archive  Cross-compiled Valhalla tar.gz

Optional:
  --target   Remote install directory (default: /opt/valhalla)
  --data     Local routing data dir to sync (valhalla.json, tiles, etc.)
  --port     SSH port (default: 22)
  --help     Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      PI_HOST="$2"
      shift 2
      ;;
    --user)
      PI_USER="$2"
      shift 2
      ;;
    --archive)
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    --target)
      TARGET_DIR="$2"
      shift 2
      ;;
    --data)
      DATA_DIR="$2"
      shift 2
      ;;
    --port)
      PI_PORT="$2"
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

if [[ -z "$PI_HOST" || -z "$PI_USER" || -z "$ARCHIVE_PATH" ]]; then
  echo "Error: --host, --user and --archive are required." >&2
  usage
  exit 1
fi

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "Error: archive not found: $ARCHIVE_PATH" >&2
  exit 1
fi

for cmd in rsync ssh scp; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
done

PI_REMOTE="$PI_USER@$PI_HOST"
SSH_CMD=(ssh -p "$PI_PORT")

echo "[remote] Prepare target: $TARGET_DIR"
"${SSH_CMD[@]}" "$PI_REMOTE" "sudo mkdir -p '$TARGET_DIR' && sudo chown '$PI_USER':'$PI_USER' '$TARGET_DIR'"

echo "[copy] Binary archive -> Pi"
scp -P "$PI_PORT" "$ARCHIVE_PATH" "$PI_REMOTE:$TARGET_DIR/valhalla-aarch64.tar.gz"

echo "[remote] Extract archive"
"${SSH_CMD[@]}" "$PI_REMOTE" "cd '$TARGET_DIR' && tar -xzf valhalla-aarch64.tar.gz && rm -f valhalla-aarch64.tar.gz"

if [[ -n "$DATA_DIR" ]]; then
  if [[ ! -d "$DATA_DIR" ]]; then
    echo "Error: data directory not found: $DATA_DIR" >&2
    exit 1
  fi
  echo "[copy] Sync routing data -> Pi"
  rsync -av --delete -e "ssh -p $PI_PORT" "$DATA_DIR/" "$PI_REMOTE:$TARGET_DIR/data/"
fi

echo "Done"
echo "Valhalla deployed to: $PI_HOST:$TARGET_DIR"
echo "Start hint on Pi:"
echo "  cd $TARGET_DIR && ./bin/valhalla_service ./data/valhalla.json 1"
