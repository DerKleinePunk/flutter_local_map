#!/usr/bin/env bash
# speedtest-planetiler.sh – Bauzeit tilemaker (dieses Profil) gegen planetiler
#
# Baut dieselbe OSM-Datei zweimal bis z14 und schreibt Zeit, Speicher und
# Dateigroesse nach result.txt:
#   1. tilemaker im Container, mit process-openmaptiles.lua aus diesem Ordner
#      und config-openmaptiles-z17.json, auf z14 gekappt
#   2. planetiler (OpenMapTiles-Standardprofil) direkt mit Java
# Mit TM_Z17=1 kommt ein dritter Lauf dazu: tilemaker mit dem vollen Profil
# bis z17, so wie die Karten fuer local_map gebaut werden.
#
# Nutzung:
#   PLANETILER_JAR=/pfad/planetiler.jar \
#     ./speedtest-planetiler.sh <osm.pbf> [west,sued,ost,nord]
#
# Die .pbf muss im Arbeitsverzeichnis liegen (der Container sieht nur das).
#
# Umgebungsvariablen:
#   WORK_DIR        Arbeitsverzeichnis (default: Ordner der .pbf). Bei
#                   podman-remote muss es fuer den podman-Server sichtbar sein,
#                   unter WSL etwa unter /mnt/wsl.
#   PLANETILER_JAR  planetiler.jar (Pflicht)
#   JAVA            Java 21 oder neuer (default: java)
#   PLANETILER_XMX  Heap fuer planetiler (default: 16g; ganz DACH brauchte
#                   bei uns mit 24g knapp 36 GB RAM insgesamt)
#   PLANETILER_ARGS weitere Argumente, z. B. --download beim ersten Lauf, damit
#                   planetiler Wasserflaechen und Natural Earth selbst laedt
#   CONTAINER_CMD   docker|podman|<pfad>; sonst automatisch
#   TM_IMAGE        default: ghcr.io/systemed/tilemaker:master
#   TM_Z17=1        zusaetzlich tilemaker bis z17
#
# Hinweis zum Ausschnitt: planetiler liest mit --bounds trotzdem die ganze
# Datei und schneidet erst beim Schreiben zu, tilemaker liest mit --bbox nur
# den Ausschnitt. Fuer einen fairen Vergleich die .pbf vorher zuschneiden
# (osmium extract) oder ein ganzes Land nehmen.
#
# Gemessen am 15.11.2026 (12 Kerne, 64 GB RAM, ext4):
#   Hessen-Ausschnitt aus germany-latest:  tilemaker z14 2:58 min,
#                                          planetiler z14 6:32 min,
#                                          tilemaker z17 6:47 min
#   dach-latest ganz:                      tilemaker z14 5:42 min,
#                                          planetiler z14 19:58 min (35,9 GB RAM)

set -uo pipefail

if [ $# -lt 1 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PBF="$(realpath "$1")"
BBOX="${2:-}"
WORK_DIR="$(realpath "${WORK_DIR:-$(dirname "$PBF")}")"
OUT="$WORK_DIR/speedtest"
JAVA="${JAVA:-java}"
PLANETILER_XMX="${PLANETILER_XMX:-16g}"
TM_IMAGE="${TM_IMAGE:-ghcr.io/systemed/tilemaker:master}"
NAME="$(basename "$PBF" .osm.pbf)"

case "$PBF" in
  "$WORK_DIR"/*) ;;
  *) echo "[error] $PBF liegt nicht unter WORK_DIR=$WORK_DIR"; exit 1 ;;
esac
PBF_IN_CONTAINER="/data/${PBF#"$WORK_DIR"/}"

if [ -z "${PLANETILER_JAR:-}" ] || [ ! -f "$PLANETILER_JAR" ]; then
  echo "[error] PLANETILER_JAR zeigt auf keine Datei"
  exit 1
fi

CONTAINER_CMD="${CONTAINER_CMD:-}"
if [ -z "$CONTAINER_CMD" ]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    CONTAINER_CMD="docker"
  elif command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
  else
    echo "[error] Weder docker noch podman ist erreichbar (CONTAINER_CMD setzen)."
    exit 1
  fi
fi

mkdir -p "$OUT"
log() { echo "$(date '+%F %T') $*" | tee -a "$OUT/result.txt"; }

# Profil in den Arbeitsordner, damit der Container es sieht; z14 aus z17.
cp "$SCRIPT_DIR/process-openmaptiles.lua" "$OUT/process.lua"
cp "$SCRIPT_DIR/config-openmaptiles-z17.json" "$OUT/config-z17.json"
python3 - "$OUT/config-z17.json" "$OUT/config-z14.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
s = cfg["settings"]
s["maxzoom"] = min(s["maxzoom"], 14)
s["basezoom"] = min(s.get("basezoom", 14), 14)
s["name"] = s.get("name", "").replace("(z17)", "(z14, Speedtest)")
for layer in cfg["layers"].values():
    for key in ("minzoom", "maxzoom"):
        if key in layer:
            layer[key] = min(layer[key], 14)
json.dump(cfg, open(sys.argv[2], "w"), indent=1)
PY

# tilemaker im Container; Speicher aus der cgroup des Containers.
tm_run() { # label config ausgabe
  local label=$1 cfg=$2 out=$3 name="speedtest-$1" peak=0 m t0 t1 rc
  local bbox_arg=()
  [ -n "$BBOX" ] && bbox_arg=(--bbox "$BBOX")
  rm -f "$OUT/$out"
  "$CONTAINER_CMD" rm -f "$name" >/dev/null 2>&1
  "$CONTAINER_CMD" run -d --name "$name" -w /data -v "$WORK_DIR:/data" "$TM_IMAGE" \
    --input "$PBF_IN_CONTAINER" --output "/data/speedtest/$out" \
    --config "/data/speedtest/$cfg" --process /data/speedtest/process.lua \
    --fast --threads 0 "${bbox_arg[@]}" --store "/data/speedtest/store-$label" >/dev/null || return 1
  t0=$(date +%s)
  while [ "$(timeout 20 "$CONTAINER_CMD" inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = "true" ]; do
    m=$(timeout 20 "$CONTAINER_CMD" exec "$name" sh -c \
      'cat /sys/fs/cgroup/memory.peak 2>/dev/null || cat /sys/fs/cgroup/memory.current' 2>/dev/null | tr -dc 0-9)
    [ -n "$m" ] && [ "$m" -gt "$peak" ] && peak=$m
    sleep 10
  done
  t1=$(date +%s)
  rc=$("$CONTAINER_CMD" inspect -f '{{.State.ExitCode}}' "$name")
  "$CONTAINER_CMD" logs "$name" 2>&1 | tail -c 20000 > "$OUT/$label.log"
  "$CONTAINER_CMD" rm "$name" >/dev/null
  log "$label: exit $rc, $((t1 - t0)) s, Speicher max $((peak / 1024 / 1024)) MB (0 = nicht messbar), Datei $(stat -c %s "$OUT/$out" 2>/dev/null) Bytes"
  # Der Zwischenspeicher gehoert dem Container-Benutzer, also dort loeschen.
  "$CONTAINER_CMD" run --rm -v "$WORK_DIR:/data" --entrypoint sh "$TM_IMAGE" \
    -c "rm -rf /data/speedtest/store-$label" >/dev/null 2>&1 || true
}

log "Start: $PBF ${BBOX:+(Ausschnitt $BBOX)}"
log "tilemaker-Image: $TM_IMAGE, Container: $CONTAINER_CMD"

# 1) tilemaker, dieses Profil, z14
tm_run tm-z14 config-z14.json "$NAME-tm-z14.mbtiles"

# 2) planetiler, Standardprofil, z14
bounds_arg=()
[ -n "$BBOX" ] && bounds_arg=(--bounds="$BBOX")
# shellcheck disable=SC2086
/usr/bin/time -v -o "$OUT/time-planetiler.txt" "$JAVA" -Xmx"$PLANETILER_XMX" -jar "$PLANETILER_JAR" \
  --osm-path="$PBF" "${bounds_arg[@]}" --output="$OUT/$NAME-planetiler-z14.mbtiles" \
  --force --nodemap-type=sortedtable --download_dir="$OUT/planetiler-sources" \
  --tmpdir="$OUT/pt-tmp" ${PLANETILER_ARGS:-} > "$OUT/planetiler.log" 2>&1
rc=$?
log "planetiler-z14: exit $rc, $(grep 'Elapsed (wall' "$OUT/time-planetiler.txt" | awk '{print $NF}'), max RSS $(grep 'Maximum resident' "$OUT/time-planetiler.txt" | awk '{print $NF}') kB, Datei $(stat -c %s "$OUT/$NAME-planetiler-z14.mbtiles" 2>/dev/null) Bytes"
rm -rf "$OUT/pt-tmp"

# 3) optional tilemaker mit vollem Profil bis z17
if [ "${TM_Z17:-0}" = "1" ]; then
  tm_run tm-z17 config-z17.json "$NAME-tm-z17.mbtiles"
fi

log "Ende. Ergebnisse: $OUT/result.txt"
