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

Im Projekt liegt dafuer ein Skript mit optionaler `--bbox`-Option:

```bash
./scripts/valhalla/build_valhalla_from_pbf.sh \
  --input ./tiles-germany/germany-latest.osm.pbf \
  --output ./map/valhalla/output \
  --bbox 8.9,50.22,9.9,50.85 \
  --region vogelsberg
```

Windows/Powershell Variante:

```powershell
./scripts/valhalla/build_valhalla_from_pbf.ps1 `
  -InputPbf ./tiles-germany/germany-latest.osm.pbf `
  -Output ./map/valhalla/output `
  -Bbox "8.9,50.22,9.9,50.85" `
  -Region vogelsberg
```

Hinweise:

- `--bbox` erwartet `west,south,east,north` in WGS84.
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
