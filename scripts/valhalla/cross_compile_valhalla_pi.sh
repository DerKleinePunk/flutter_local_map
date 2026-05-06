#!/usr/bin/env bash
set -euo pipefail

# Cross-compile Valhalla for Raspberry Pi (ARM64) without Docker.
#
# Example:
#   ./scripts/valhalla/cross_compile_valhalla_pi.sh \
#     --source ~/src/valhalla \
#     --sysroot ./map/valhalla/pi-sysroot \
#     --build ./map/valhalla/build-aarch64 \
#     --install ./map/valhalla/install-aarch64

SOURCE_DIR=""
SYSROOT_DIR=""
BUILD_DIR=""
INSTALL_DIR=""
CMAKE_BUILD_TYPE="Release"

usage() {
  cat <<'EOF'
Usage:
  cross_compile_valhalla_pi.sh --source <valhalla-src> --sysroot <dir> --build <dir> --install <dir> [options]

Required:
  --source   Path to Valhalla source repository
  --sysroot  Sysroot path fetched from Raspberry Pi
  --build    CMake build directory
  --install  Install output directory

Optional:
  --type     CMake build type (default: Release)
  --help     Show this help

Notes:
- Requires host toolchain: aarch64-linux-gnu-gcc/g++
- Requires cmake + ninja
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE_DIR="$2"
      shift 2
      ;;
    --sysroot)
      SYSROOT_DIR="$2"
      shift 2
      ;;
    --build)
      BUILD_DIR="$2"
      shift 2
      ;;
    --install)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --type)
      CMAKE_BUILD_TYPE="$2"
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

if [[ -z "$SOURCE_DIR" || -z "$SYSROOT_DIR" || -z "$BUILD_DIR" || -z "$INSTALL_DIR" ]]; then
  echo "Error: --source, --sysroot, --build and --install are required." >&2
  usage
  exit 1
fi

for cmd in cmake ninja aarch64-linux-gnu-gcc aarch64-linux-gnu-g++; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
done

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "Error: source directory not found: $SOURCE_DIR" >&2
  exit 1
fi

if [[ ! -d "$SYSROOT_DIR/usr/include" || ! -d "$SYSROOT_DIR/usr/lib" ]]; then
  echo "Error: invalid sysroot (missing usr/include or usr/lib): $SYSROOT_DIR" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR" "$INSTALL_DIR"

TOOLCHAIN_FILE="$BUILD_DIR/pi-aarch64-toolchain.cmake"
cat > "$TOOLCHAIN_FILE" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_SYSROOT "$SYSROOT_DIR")

set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)

set(CMAKE_FIND_ROOT_PATH "$SYSROOT_DIR")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_C_FLAGS "--sysroot=$SYSROOT_DIR")
set(CMAKE_CXX_FLAGS "--sysroot=$SYSROOT_DIR")
set(CMAKE_EXE_LINKER_FLAGS "--sysroot=$SYSROOT_DIR")
EOF

echo "[cmake] Configure"
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"

echo "[cmake] Build"
cmake --build "$BUILD_DIR" -- -k 0

echo "[cmake] Install"
cmake --install "$BUILD_DIR"

ARCHIVE_PATH="$INSTALL_DIR/../valhalla-aarch64.tar.gz"
echo "[pack] $ARCHIVE_PATH"
tar -C "$INSTALL_DIR" -czf "$ARCHIVE_PATH" .

echo "Done"
echo "Installed to: $INSTALL_DIR"
echo "Archive: $ARCHIVE_PATH"
