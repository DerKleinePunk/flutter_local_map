#!/usr/bin/env python3
"""Hilfe fuer build_contours.sh: welche DEM-Kacheln braucht ein Gebiet?

  contours_tiles.py tiles <zoom> --bbox W,S,E,N
  contours_tiles.py tiles <zoom> --poly gebiet.poly
      gibt je Kachel eine Zeile "x y" aus (XYZ-Schema)

  contours_tiles.py geojson gebiet.poly ausgabe.geojson
      schreibt die Flaeche einer Osmosis-.poly-Datei als GeoJSON
      (fuer gdalwarp -cutline)

  contours_tiles.py bbox gebiet.poly
      gibt "W,S,E,N" der Flaeche aus

Ohne Fremdpakete; der Schnitt Kachel/Flaeche ist bewusst grob: eine Kachel
zaehlt, wenn eine ihrer Ecken oder ihr Mittelpunkt in der Flaeche liegt oder
ein Punkt der Grenze in der Kachel. Bei z12 (~10 km) und Landesgrenzen
reicht das; zugeschnitten wird danach ohnehin genau an der Grenze.
"""

import json
import math
import sys


def read_poly(path):
    """Osmosis-.poly: Ringe, '!' vor dem Namen = Loch."""
    rings = []
    with open(path, encoding="utf-8") as fh:
        lines = [line.strip() for line in fh]
    i = 1  # erste Zeile ist der Name
    while i < len(lines):
        name = lines[i]
        i += 1
        if name == "END" or name == "":
            continue
        ring = []
        while i < len(lines) and lines[i] != "END":
            lon, lat = (float(v) for v in lines[i].split())
            ring.append((lon, lat))
            i += 1
        i += 1
        rings.append((name.startswith("!"), ring))
    return rings


def inside(rings, lon, lat):
    hit = False
    for hole, ring in rings:
        c = False
        n = len(ring)
        for k in range(n):
            x1, y1 = ring[k]
            x2, y2 = ring[(k + 1) % n]
            if (y1 > lat) != (y2 > lat):
                if lon < (x2 - x1) * (lat - y1) / (y2 - y1) + x1:
                    c = not c
        if c:
            hit = not hit if hole else True
    return hit


def lon2x(lon, z):
    return int((lon + 180.0) / 360.0 * 2**z)


def lat2y(lat, z):
    r = math.radians(lat)
    return int((1.0 - math.log(math.tan(r) + 1.0 / math.cos(r)) / math.pi) / 2.0 * 2**z)


def x2lon(x, z):
    return x / 2**z * 360.0 - 180.0


def y2lat(y, z):
    return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / 2**z))))


def bbox_of(rings):
    pts = [p for hole, ring in rings if not hole for p in ring]
    return (min(p[0] for p in pts), min(p[1] for p in pts),
            max(p[0] for p in pts), max(p[1] for p in pts))


def tiles(z, bbox, rings=None):
    w, s, e, n = bbox
    border = {}
    if rings:
        for _, ring in rings:
            for lon, lat in ring:
                border[(lon2x(lon, z), lat2y(lat, z))] = True
    for x in range(lon2x(w, z), lon2x(e, z) + 1):
        for y in range(lat2y(n, z), lat2y(s, z) + 1):
            if rings is None or (x, y) in border:
                yield x, y
                continue
            lon0, lon1 = x2lon(x, z), x2lon(x + 1, z)
            lat0, lat1 = y2lat(y + 1, z), y2lat(y, z)
            probes = [(lon0, lat0), (lon0, lat1), (lon1, lat0), (lon1, lat1),
                      ((lon0 + lon1) / 2, (lat0 + lat1) / 2)]
            if any(inside(rings, lo, la) for lo, la in probes):
                yield x, y


def main(argv):
    if len(argv) >= 2 and argv[1] == "tiles":
        z = int(argv[2])
        if argv[3] == "--bbox":
            bbox = tuple(float(v) for v in argv[4].split(","))
            found = tiles(z, bbox)
        else:
            rings = read_poly(argv[4])
            found = tiles(z, bbox_of(rings), rings)
        for x, y in found:
            print(x, y)
    elif len(argv) == 4 and argv[1] == "geojson":
        rings = read_poly(argv[2])
        outer = [[list(p) for p in r] + [list(r[0])] for h, r in rings if not h]
        holes = [[list(p) for p in r] + [list(r[0])] for h, r in rings if h]
        # Loecher dem ersten Ring zuordnen, in dem ihr erster Punkt liegt.
        polys = [[ring] for ring in outer]
        for hole in holes:
            for poly in polys:
                if inside([(False, [tuple(p) for p in poly[0]])], *hole[0]):
                    poly.append(hole)
                    break
        geo = {"type": "FeatureCollection", "features": [{
            "type": "Feature", "properties": {},
            "geometry": {"type": "MultiPolygon", "coordinates": polys}}]}
        with open(argv[3], "w", encoding="utf-8") as fh:
            json.dump(geo, fh)
    elif len(argv) == 3 and argv[1] == "bbox":
        print(",".join(f"{v:.6f}" for v in bbox_of(read_poly(argv[2]))))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
