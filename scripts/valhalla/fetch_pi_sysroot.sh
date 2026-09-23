#!/usr/bin/env bash
set -euo pipefail

# Fetch a Raspberry Pi sysroot for cross-compiling ARM64 binaries on the host.
#
# Example:
#   ./scripts/valhalla/fetch_pi_sysroot.sh \
#     --host 192.168.2.50 \
#     --user pi \
#     --out ./map/valhalla/pi-sysroot

PI_HOST=""
PI_USER=""
OUT_DIR=""
PI_PORT="22"

usage() {
  cat <<'EOF'
Usage:
  fetch_pi_sysroot.sh --host <ip-or-host> --user <ssh-user> --out <dir> [options]

Required:
  --host   Raspberry Pi host/IP
  --user   SSH user
  --out    Output directory for sysroot

Optional:
  --port   SSH port (default: 22)
  --help   Show this help
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
    --out)
      OUT_DIR="$2"
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

if [[ -z "$PI_HOST" || -z "$PI_USER" || -z "$OUT_DIR" ]]; then
  echo "Error: --host, --user and --out are required." >&2
  usage
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  echo "Error: rsync not found. Install rsync on host." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

SSH_CMD="ssh -p $PI_PORT"
PI_REMOTE="$PI_USER@$PI_HOST"

# Minimal but practical sysroot for C/C++ linking on Pi.
# We include /lib, /usr/include and /usr/lib recursively.
for path in /lib /usr/include /usr/lib; do
  echo "[sync] $PI_REMOTE:$path -> $OUT_DIR$path"
  rsync -a --delete -e "$SSH_CMD" "$PI_REMOTE:$path" "$OUT_DIR$(dirname "$path")/"
done

# Capture dynamic linker path and architecture details for diagnostics.
mkdir -p "$OUT_DIR/.meta"
$SSH_CMD "$PI_REMOTE" "uname -a; ldd --version | head -n 1" > "$OUT_DIR/.meta/pi-runtime.txt" || true

echo "Done"
echo "Sysroot prepared at: $OUT_DIR"
