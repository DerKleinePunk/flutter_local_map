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
CROSS_PREFIX="${CROSS_PREFIX:-aarch64-linux-gnu}"
C_COMPILER=""
CXX_COMPILER=""
NINJA_CMD=""
NINJA_PATH=""
PKG_CONFIG_LIBDIR=""

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
  --prefix   Cross-Compiler prefix (default: aarch64-linux-gnu)
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
    --prefix)
      CROSS_PREFIX="$2"
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

if ! command -v cmake >/dev/null 2>&1; then
  echo "Error: required command not found: cmake" >&2
  exit 1
fi

if command -v ninja >/dev/null 2>&1; then
  NINJA_CMD="ninja"
elif command -v ninja-build >/dev/null 2>&1; then
  NINJA_CMD="ninja-build"
else
  echo "Error: required command not found: ninja (or ninja-build)" >&2
  echo "Install hint (Ubuntu/Debian): sudo apt install -y ninja-build" >&2
  exit 1
fi
NINJA_PATH="$(command -v "$NINJA_CMD")"

C_COMPILER="${CROSS_PREFIX}-gcc"
CXX_COMPILER="${CROSS_PREFIX}-g++"
if ! command -v "$C_COMPILER" >/dev/null 2>&1 || ! command -v "$CXX_COMPILER" >/dev/null 2>&1; then
  echo "Error: cross compiler not found: $C_COMPILER / $CXX_COMPILER" >&2
  echo "Install hint (Ubuntu/Debian):" >&2
  echo "  sudo apt update && sudo apt install -y gcc-${CROSS_PREFIX} g++-${CROSS_PREFIX}" >&2
  echo "Example for Raspberry Pi ARM64:" >&2
  echo "  sudo apt install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu" >&2
  exit 1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "Error: source directory not found: $SOURCE_DIR" >&2
  exit 1
fi

if [[ ! -d "$SYSROOT_DIR/usr/include" || ! -d "$SYSROOT_DIR/usr/lib" ]]; then
  echo "Error: invalid sysroot (missing usr/include or usr/lib): $SYSROOT_DIR" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR" "$INSTALL_DIR"

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)"
SYSROOT_DIR="$(cd "$SYSROOT_DIR" && pwd -P)"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd -P)"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"

PKG_CONFIG_LIBDIR="$SYSROOT_DIR/usr/lib/aarch64-linux-gnu/pkgconfig:$SYSROOT_DIR/usr/lib/pkgconfig:$SYSROOT_DIR/usr/share/pkgconfig"

# Early check to fail fast with a clear hint when the sysroot is incomplete.
if [[ ! -f "$SYSROOT_DIR/usr/include/curl/curl.h" && ! -f "$SYSROOT_DIR/usr/include/aarch64-linux-gnu/curl/curl.h" ]]; then
  echo "Error: libcurl headers not found in sysroot." >&2
  echo "Expected one of:" >&2
  echo "  $SYSROOT_DIR/usr/include/curl/curl.h" >&2
  echo "  $SYSROOT_DIR/usr/include/aarch64-linux-gnu/curl/curl.h" >&2
  echo "On the Pi install dev deps (e.g. libcurl4-openssl-dev) and re-run fetch_pi_sysroot.sh." >&2
  exit 1
fi

if [[ ! -f "$SYSROOT_DIR/usr/lib/aarch64-linux-gnu/pkgconfig/libcurl.pc" && ! -f "$SYSROOT_DIR/usr/lib/pkgconfig/libcurl.pc" ]]; then
  echo "Error: libcurl.pc not found in sysroot pkg-config paths." >&2
  echo "Checked:" >&2
  echo "  $SYSROOT_DIR/usr/lib/aarch64-linux-gnu/pkgconfig/libcurl.pc" >&2
  echo "  $SYSROOT_DIR/usr/lib/pkgconfig/libcurl.pc" >&2
  echo "On the Pi install dev deps (e.g. libcurl4-openssl-dev) and re-run fetch_pi_sysroot.sh." >&2
  exit 1
fi

TOOLCHAIN_FILE="$BUILD_DIR/pi-aarch64-toolchain.cmake"
cat > "$TOOLCHAIN_FILE" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_SYSROOT "$SYSROOT_DIR")

set(CMAKE_C_COMPILER "$C_COMPILER")
set(CMAKE_CXX_COMPILER "$CXX_COMPILER")

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
PKG_CONFIG_SYSROOT_DIR="$SYSROOT_DIR" \
PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR" \
PKG_CONFIG_PATH="" \
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -G "Ninja" \
  -DCMAKE_MAKE_PROGRAM="$NINJA_PATH" \
  -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
  -DENABLE_SERVICES=OFF \
  -DENABLE_PYTHON_BINDINGS=OFF \
  -DENABLE_TESTS=OFF \
  -DENABLE_CCACHE=OFF

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
