# Valhalla Offline Setup (Build + Pi Runtime)

Stand: 2026-04-08

## Ziel

Valhalla als zweite, rein lokale Datenquelle fuer Routing bereitstellen.
Die Kartenanzeige (Raster/MBTiles) bleibt unveraendert und getrennt.

## Architektur

- Quelle: ein OSM-Extrakt (`.osm.pbf`), z. B. `hessen-latest.osm.pbf`
- Pipeline A (Karte): MBTiles fuer Anzeige
- Pipeline B (Routing): Valhalla-Graphdaten aus derselben OSM-Quelle
- Runtime: Flutter spricht lokal per HTTP mit Valhalla (`127.0.0.1:8002`)

## Verzeichnisvorschlag

```text
map_local/
  map/
    valhalla/
      input/
        hessen-latest.osm.pbf
      output/
        valhalla.json
        valhalla_tiles.tar
        admins.sqlite
        timezones.sqlite
```

## Vorgehen

## 1) Kleine Testregion waehlen

Start mit einer kleinen Region (z. B. Vogelsberg) fuer schnelle Iterationen.
Erst nach erfolgreichem End-to-End-Test auf ganz Hessen erweitern.

## 2) Daten auf Build-Rechner vorbereiten

Empfehlung: Build-Vorbereitung auf starkem Linux-Rechner, dann Artefakte auf Pi kopieren.

Wichtig fuer das verwendete GIS-OPS-Image:

- Das Image erwartet im Standardfall Daten unter `/custom_files`.
- Ein `.osm.pbf` im Zielordner reicht, damit der Container `valhalla.json`, Admins, Timezones und Routing-Tiles selbst erzeugt.
- Ja, du kannst Bounds indirekt mitgeben: erst aus `germany-latest.osm.pbf` einen bounded Extract erstellen, dann nur diesen Extract dem Container bereitstellen.

Im Projekt liegt dafuer ein Skript mit optionaler `--bbox`-Option und Regions-Presets fuer `vogelsberg` und `braunschweig`:

```bash
./scripts/valhalla/build_valhalla_from_pbf.sh \
  --input ./tiles-germany/germany-latest.osm.pbf \
  --output ./map/valhalla/output \
  --region vogelsberg
```

Braunschweig mit Umland:

```bash
./scripts/valhalla/build_valhalla_from_pbf.sh \
  --input ./tiles-germany/germany-latest.osm.pbf \
  --output ./map/valhalla/output \
  --region braunschweig
```

Windows/Powershell Variante:

```powershell
./scripts/valhalla/build_valhalla_from_pbf.ps1 `
  -InputPbf ./tiles-germany/germany-latest.osm.pbf `
  -Output ./map/valhalla/output `
  -Region vogelsberg
```

Braunschweig mit Umland:

```powershell
./scripts/valhalla/build_valhalla_from_pbf.ps1 `
  -InputPbf ./tiles-germany/germany-latest.osm.pbf `
  -Output ./map/valhalla/output `
  -Region braunschweig
```

Hinweise:

- `--bbox` erwartet `west,south,east,north` in WGS84.
- Fuer `--region vogelsberg` wird automatisch `8.9,50.22,9.9,50.85` verwendet.
- Fuer `--region braunschweig` wird automatisch `10.28,52.12,10.78,52.42` verwendet.
- Eine explizite `--bbox` bzw. `-Bbox` ueberschreibt das Regions-Preset.
- Fuer `--bbox` wird `osmium` auf dem Build-Host benoetigt.
- Ohne `--bbox` wird das Input-PBF direkt kopiert.
- Das Skript legt den resultierenden Extract direkt im Output-Ordner ab, damit der Container ihn spaeter unter `/custom_files` findet.
- Eine leere oder kaputte `valhalla.json` wird entfernt, damit der Container sie selbst regeneriert.

## 3) Runtime-Dateien auf Pi kopieren

Auf dem Pi z. B. nach `/opt/valhalla`:

- mindestens: `*.osm.pbf` des Zielgebiets
- optional bereits vorhanden: `valhalla.json`
- optional bereits vorhanden: `valhalla_tiles.tar` oder `valhalla_tiles/`
- optional bereits vorhanden: `admins.sqlite`
- optional bereits vorhanden: `timezones.sqlite`

Wenn nur das `.osm.pbf` vorhanden ist, baut der Container den Rest beim ersten Start selbst.

## 4) Valhalla auf Pi starten

Beispiel mit Docker:

```bash
docker run -d --name valhalla \
  --restart unless-stopped \
  -p 8002:8002 \
  -v /opt/valhalla:/custom_files \
  -e use_tiles_ignore_pbf=True \
  -e force_rebuild=False \
  -e serve_tiles=True \
  ghcr.io/gis-ops/docker-valhalla/valhalla:latest
```

Alternativ im Projekt mit Skript:

```bash
./scripts/valhalla/run_valhalla_server.sh \
  --data ./map/valhalla/output \
  --port 8002
```

Windows/Powershell Variante:

```powershell
./scripts/valhalla/run_valhalla_server.ps1 `
  -Data ./map/valhalla/output `
  -Port 8002
```

## Optional: Native Pi-Binaries ohne Docker (Cross-Compile)

Wenn Docker auf dem Pi nicht gewuenscht ist, koennen Valhalla-Binaries als ARM64 auf dem Host gebaut und dann auf den Pi kopiert werden.

Voraussetzungen auf dem Host:

- `cmake`, `ninja-build`
- Cross-Toolchain: `gcc-aarch64-linux-gnu`, `g++-aarch64-linux-gnu`
- `rsync`, `ssh`, `scp`

Empfohlene Reihenfolge:

1) Pi-Sysroot ziehen (hier mit deiner Pi-IP `192.168.2.50`):

```bash
./scripts/valhalla/fetch_pi_sysroot.sh \
  --host 192.168.2.50 \
  --user <pi-user> \
  --out ./map/valhalla/pi-sysroot
```

2) Valhalla fuer ARM64 cross-compilen:

```bash
./scripts/valhalla/cross_compile_valhalla_pi.sh \
  --source /pfad/zum/valhalla-source \
  --sysroot ./map/valhalla/pi-sysroot \
  --build ./map/valhalla/build-aarch64 \
  --install ./map/valhalla/install-aarch64
```

Ergebnis:

- Installationsordner: `./map/valhalla/install-aarch64`
- Archiv: `./map/valhalla/valhalla-aarch64.tar.gz`

3) Binaries (optional plus Daten) auf den Pi deployen:

```bash
./scripts/valhalla/deploy_valhalla_pi.sh \
  --host 192.168.2.50 \
  --user <pi-user> \
  --archive ./map/valhalla/valhalla-aarch64.tar.gz \
  --target /opt/valhalla \
  --data ./map/valhalla/output
```

WSL-Hinweis (wichtig):

- In WSL besser einen absoluten Remote-Pfad verwenden, z. B. `/home/pi/test/valhalla`.
- Wenn `~` genutzt wird, dann nur gequotet uebergeben (`--target '~/test/valhalla'`), damit es nicht lokal expandiert.

SSH-Key-Login einrichten (empfohlen, keine Passwort-Prompts bei ssh/scp/rsync):

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
[[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "wsl-valhalla-$(hostname)"
ssh-copy-id -i ~/.ssh/id_ed25519.pub -o StrictHostKeyChecking=accept-new pi@192.168.2.50
ssh -o BatchMode=yes -o ConnectTimeout=8 pi@192.168.2.50 'echo KEY_OK'
```

Optional: Alias in WSL fuer schnellen Deploy:

```bash
echo "alias deploy-pi='cd /mnt/d/Projects/Privat/Flutter/map_local && ./scripts/valhalla/deploy_valhalla_pi.sh --host 192.168.2.50 --user pi --archive ./map/valhalla/valhalla-aarch64.tar.gz --target /home/pi/test/valhalla --data ./map/valhalla/output'" >> ~/.bashrc
source ~/.bashrc
deploy-pi
```

4) Auf dem Pi nativ starten (Beispiel):

```bash
cd /opt/valhalla
./bin/valhalla_service ./data/valhalla.json 1
```

Hinweise:

- Cross-Compile muss zur Pi-Architektur passen (`aarch64` fuer 64-bit Raspberry Pi OS).
- Sysroot und Pi-OS sollten zusammenpassen (glibc-Versionen).
- Fuer produktiven Betrieb empfiehlt sich ein systemd-Service auf dem Pi.

## 5) Route lokal testen

```bash
curl -X POST http://127.0.0.1:8002/route \
  -H "Content-Type: application/json" \
  -d '{
    "locations": [
      {"lat": 50.55, "lon": 9.68},
      {"lat": 50.56, "lon": 9.70}
    ],
    "costing": "auto",
    "directions_options": {"units": "kilometers"}
  }'
```

Erwartung: JSON mit `trip`, `legs`, `shape`, `maneuvers`.

## 6) Flutter-Anbindung

- Neuer Service: `lib/services/valhalla_routing_service.dart`
- Anfrage an `POST /route`
- Rueckgabe: Geometrie + Distanz + Dauer + Manoever
- Karte bleibt bei euren Raster-/Vektor-MBTiles unveraendert

## Troubleshooting

- HTTP 4xx/5xx: Request-JSON pruefen, besonders `locations` und `costing`.
- Keine Geometrie: OSM-Region deckt Start/Ziel nicht ab.
- Hoher RAM-Verbrauch beim Build: kleinere Region, Build ausserhalb des Pi.
- Service down: Logs des Containers pruefen (`docker logs valhalla`).

## Nächste Schritte im Projekt

1. Service in UI-Flow integrieren (z. B. Start/Ziel aus Suche -> Route).
2. Polyline in `MapView` als Overlay zeichnen.
3. Healthcheck beim App-Start (Valhalla erreichbar?).
4. Optional: systemd-Unit fuer Pi statt Docker.
