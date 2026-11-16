# Test-Pi neu aufbauen (Vorlage: jeep-pi)

Was ein Raspberry Pi braucht, damit er als Test-Pi für local_map und CarNine
taugt, so wie `jeep-pi`. Stand: 16.11.2026, abgelesen auf jeep-pi
(Pi 4, 7,6 GB RAM, SSD über USB).

Neue Pakete oder Werkzeuge auf dem Test-Pi kommen **hier** in die Liste
„Nachträge“ unten, mit Datum und Grund.

## 1. Grundsystem

- **Raspberry Pi OS Lite 64 Bit** auf Basis Debian 13 „trixie“ (aarch64), mit dem
  Raspberry Pi Imager. Benutzer `pi`, SSH an, WLAN-Land DE.
- `pi` in den Gruppen `sudo render video input audio gpio i2c spi`
  (`sudo usermod -aG render,video,input pi`). `sudo` ohne Passwort, wie bei
  der Imager-Vorgabe.
- **Linger** für `pi`: `sudo loginctl enable-linger pi`. Dann gibt es
  `/run/user/1000` auch ohne Anmeldung, und der Embedder findet sein
  XDG_RUNTIME_DIR.

### `/boot/firmware/cmdline.txt`

Am Ende der einen Zeile ergänzen, wenn das Waveshare-Panel über den
Audio-Splitter hängt:

```
drm.edid_firmware=HDMI-A-1:edid/waveshare-7h-splitter-261013.bin
```

Die EDID-Dateien liegen in [`../edid/`](../edid/) und gehören nach
`/lib/firmware/edid/`. Welche wofür: [`../waveshare-1024x600-full-kms.md`](../waveshare-1024x600-full-kms.md).
Ein echtes 7C-Panel ohne Splitter braucht **keine** Vorgabe.

### `/boot/firmware/config.txt` (Abweichungen vom Standard)

```
dtoverlay=vc4-kms-v3d          # Full KMS, kein fkms
dtparam=i2c_arm=on
dtoverlay=i2c-rtc,ds3231       # Uhr (RTC)
dtoverlay=pwm-2chan,pin=18,func=2,pin2=19,func2=2
[pi4]
dtoverlay=uart5
```

## 2. Pakete

```sh
sudo apt-get update
# Laufzeit für Embedder, Karten-App und CarNine-Frontend
sudo apt-get install -y seatd fonts-dejavu-core adwaita-icon-theme \
    libsqlite3-0 libegl1 libgles2 libgbm1 libinput10 libxkbcommon0 \
    ffmpeg v4l-utils
# Test- und Messwerkzeuge
sudo apt-get install -y bc tcpdump jq curl zstd rsync python3 python3-venv \
    evtest libinput-tools drm-info kms++-utils strace gdb htop ncdu \
    i2c-tools gpiod sqlite3 spatialite-bin
# Valhalla selbst bauen (siehe 3.)
sudo apt-get install -y --no-install-recommends git cmake make pkg-config \
    g++ gcc ninja-build libtool autoconf automake libcurl4-openssl-dev \
    zlib1g-dev liblz4-dev libprotobuf-dev protobuf-compiler libgeos-dev \
    libgeos++-dev libluajit-5.1-dev libspatialite-dev libsqlite3-dev \
    libgeotiff-dev libzmq3-dev libczmq-dev libboost-dev
sudo systemctl enable --now seatd
```

- **seatd** ist Pflicht. Ohne ihn hängt `homescreen` beim Start über SSH ohne
  Fehlermeldung.
- **adwaita-icon-theme**: Ohne es ist der Mauszeiger unsichtbar
  (`[DrmCursor] no XCursor theme found`). Gestartet wird mit `-t Adwaita`.
- **fonts-dejavu-core**: Ohne es zeigt die Karte keine Beschriftung.
- **ffmpeg**: für die Rückfahrkamera (video_grabber) und Medien in CarNine.
- `carnine-voice` (Sprachausgabe) kommt aus dem CarNine-Paket, nicht aus Debian.

## 3. Valhalla 3.9.0

Mit [`werkzeuge/build_valhalla_on_pi.sh`](werkzeuge/build_valhalla_on_pi.sh)
nativ nach `/opt/valhalla` gebaut, mit prime_server, 3 Jobs. Dauert einige
Stunden.

- Daten: `~/valhalla-data/` mit `valhalla.json`, `valhalla_tiles.tar`
  (Symlink auf den aktuellen Stand, z. B. `valhalla_tiles-dach-261016.tar`),
  `admins.sqlite` und `timezones.sqlite` aus demselben Bau.
- Dienst: [`units/valhalla.service`](units/valhalla.service) nach
  `/etc/systemd/system/`, dann `sudo systemctl enable --now valhalla`.
  Er lauscht nur auf `127.0.0.1:8002` und läuft als `pi`.
- Valhalla 3.9.0 liest Kacheln aus 3.5.1 und aus 3.9.1, gemessen am
  10.11. und am 16.11.2026.
- `valhalla_build_extract` (liegt mit in `/opt/valhalla/bin`) baut ein tar mit
  `index.bin`. Ohne Index braucht Valhalla beim Start etwa 16 s statt 1,5 s
  (gemessen am 16.11.2026).

## 4. Kartendaten

- `~/.local/share/homescreen/offline_maps/` mit `germany.mbtiles` und
  `germany_names.db`. Beides sind Symlinks auf den aktiven Stand, auf jeep-pi
  `dach-261016.mbtiles` und `dach_names-261016.db`.
- Der Name `germany.mbtiles` ist fest, sagt aber nichts über den Inhalt.
  Vektor oder Raster prüft man mit `sqlite3`, siehe Skill `run-map-app`.

## 5. CarNine (Weg B: eigene Units statt Paket)

- Das Backend liegt unter `~/carnine-test/` (`bin/`, `var/`, `config.d/`), das
  Frontend als Bündel unter `~/carnine-frontend/`. Ein neues Frontend aus dem
  `.deb` packt man mit `dpkg-deb -x` aus und nimmt `opt/carnine/frontend/`.
  Der alte Ordner bleibt als `~/carnine-frontend.vor-<commit>` liegen, als
  Rückweg.
- Units: [`units/`](units/) nach `/etc/systemd/system/`, dann
  `sudo systemctl daemon-reload && sudo systemctl enable carnine-backend
  carnine-frontend carnine-ac3`.
- Die Karte für das Frontend kommt aus `CARNINE_MAP_TILES` in der Unit. Zum
  Probieren einer anderen Karte reicht ein Drop-in
  `/etc/systemd/system/carnine-frontend.service.d/<name>.conf` mit
  `Environment=CARNINE_MAP_TILES=…`. Zurück: Drop-in löschen,
  `daemon-reload`, nur das Frontend neu starten.
- **Lautstärke** an jeep-pi nicht hochdrehen: Dort hängt eine 160-W-Endstufe.

## 6. Eigene Werkzeuge (in `~` auf dem Pi)

| Datei | Wozu | Quelle |
|---|---|---|
| `~/drm_shot.py` | Bildschirmfoto vom DRM-Scanout: `sudo python3 ~/drm_shot.py aus.png /dev/dri/card0` | [`werkzeuge/drm_shot.py`](werkzeuge/drm_shot.py) |
| `~/demo/touchplay` | Touch-Gesten per uinput (tap, swipe, pinch), z. B. `printf 'tap 974 237\n' \| sudo ~/demo/touchplay`. Ein Prozess je Ablauf, Panel 1024×600 | [`werkzeuge/touchplay.c`](werkzeuge/touchplay.c), statisch bauen: `aarch64-linux-gnu-gcc -O2 -Wall -static -o touchplay touchplay.c` |
| `~/build_valhalla_on_pi.sh` | Valhalla bauen (siehe 3.) | [`werkzeuge/build_valhalla_on_pi.sh`](werkzeuge/build_valhalla_on_pi.sh) |

- touchplay braucht `sudo`, weil `/dev/uinput` root gehört.
- Das Paket-Frontend von CarNine hat kein MCP. Bedient wird es mit touchplay,
  Bilder kommen von drm_shot.
- Die Demo-App aus diesem Repo hat MCP, wenn sie mit
  `-D BUILD_ACCESSIBILITY=ON -D BUILD_MCP=ON` gebaut und mit `--enable-mcp`
  gestartet wird.

## Nachträge

| Datum | Was | Warum |
|---|---|---|
| 16.11.2026 | `bc`, `tcpdump` | `bc` für Zeitrechnung in Messskripten; `tcpdump` fehlte beim Verkehrs-Gerätetest am 15.11. (Ersatz war `ss -tnp` alle 0,2 s) |
| 16.11.2026 | `sqlite3` (Kommandozeile) | MBTiles-Metadaten auf dem Pi prüfen (`format`, `bounds`); fehlte am 15.11. |
| 16.11.2026 | EDID `waveshare-7h-splitter-261013.bin` ins Repo übernommen | lag bisher nur auf jeep-pi unter `/lib/firmware/edid/` |
