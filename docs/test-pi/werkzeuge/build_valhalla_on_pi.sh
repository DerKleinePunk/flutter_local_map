#!/bin/bash
# Baut prime_server und Valhalla nativ auf dem Pi nach /opt/valhalla.
set -euo pipefail
VALHALLA_TAG=3.9.0
PREFIX=/opt/valhalla
SRC=$HOME/valhalla-build
JOBS=3   # 4 Kerne, einer bleibt frei; mit 4 Jobs wird es beim Linken knapp

echo "== $(date) Abhaengigkeiten"
sudo apt-get install -y -q --no-install-recommends \
  git cmake make pkg-config g++ gcc ninja-build \
  libtool autoconf automake \
  libcurl4-openssl-dev zlib1g-dev liblz4-dev libprotobuf-dev protobuf-compiler \
  libgeos-dev libgeos++-dev libluajit-5.1-dev libspatialite-dev libsqlite3-dev \
  libgeotiff-dev libzmq3-dev libczmq-dev libboost-dev jq spatialite-bin

mkdir -p "$SRC"; cd "$SRC"

echo "== $(date) prime_server"
[ -d prime_server ] || git clone --recurse-submodules --depth 1 https://github.com/kevinkreiser/prime_server.git
cd prime_server
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX -DENABLE_TESTS=OFF
cmake --build build -j $JOBS
sudo cmake --install build
cd ..

echo "== $(date) valhalla $VALHALLA_TAG"
[ -d valhalla ] || git clone --recurse-submodules --depth 1 --branch $VALHALLA_TAG https://github.com/valhalla/valhalla.git
cd valhalla
PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/lib/aarch64-linux-gnu/pkgconfig \
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX \
  -DCMAKE_PREFIX_PATH=$PREFIX \
  -DENABLE_TESTS=OFF -DENABLE_PYTHON_BINDINGS=OFF -DENABLE_CCACHE=OFF \
  -DENABLE_SINGLE_FILES_WERROR=OFF
cmake --build build -j $JOBS
sudo cmake --install build
echo "$PREFIX/lib" | sudo tee /etc/ld.so.conf.d/valhalla.conf >/dev/null
sudo ldconfig
echo "== $(date) FERTIG"
ls $PREFIX/bin
