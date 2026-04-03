#!/bin/bash
#cd /mnt/d/Projects/Privat/Flutter/map_local/map/tiles-germany

# Arbeitsverzeichnis anlegen
mkdir -p ../map/tiles-germany && cd ../map/tiles-germany

# Deutschland PBF (~4 GB)
wget https://download.geofabrik.de/europe/germany-latest.osm.pbf

# Küsten-/Wasserdaten
wget https://osmdata.openstreetmap.de/download/water-polygons-split-4326.zip
unzip water-polygons-split-4326.zip
rm water-polygons-split-4326.zip

docker run -it --rm --pull always -v $(pwd):/data \
  ghcr.io/systemed/tilemaker:master \
    --input /data/germany-latest.osm.pbf \
    --output /data/germany.mbtiles \
    --config /usr/share/tilemaker/resources/config-openmaptiles.json \
    --process /usr/share/tilemaker/resources/process-openmaptiles.lua \
    --bbox 5.8664,47.2701,15.0419,55.0574

docker run -it --rm --pull always -v $(pwd):/data \
  ghcr.io/systemed/tilemaker:master \
    --input /data/germany-latest.osm.pbf \
    --output /data/germany.mbtiles \
    --store /data/temp

docker run -it --rm --pull always -v $(pwd):/data \
  ghcr.io/systemed/tilemaker:master \
    --entrypoint /usr/src/app/tilemaker-server tilemaker \
    --store /data/temp \
    --help
