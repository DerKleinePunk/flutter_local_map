---
name: run-map-app
description: Startet und bedient die Karten-App map_local - lokal auf dem Entwicklungsrechner oder auf dem Test-Pi jeep-pi. Nutze diesen Skill immer, wenn die App laufen, gezeigt, durchgeklickt oder eine Aenderung im echten Programm bestaetigt werden soll (Style-Wechsel, Vektormodus, GPS-Route, Einfrieren). Deckt Build, Kacheldaten, Start und Bedienung ueber die MCP-Oberflaeche ab.
---

# Die Karten-App starten

Es gibt **zwei** Laeufe, und sie sind nicht austauschbar. Kläre zuerst, welcher gemeint ist — frage nach, wenn es aus dem Auftrag nicht hervorgeht:

| | **Lokal** | **Pi** |
|---|---|---|
| Wozu | Funktion pruefen, durchklicken, schnelle Runde | Zielgeraet, Anzeigekette, Einfrieren, echte Last |
| Ziel | WSLg-Fenster auf diesem Rechner | HDMI/Panel an `jeep-pi` |
| Backend | `wayland-egl` | `drm-kms-egl` |
| Target | `--target local` | `--target rpi4-trixie` |
| Dauer | ~2 min | ~2 min Build + rsync |

Beide Wege bauen mit **derselben Kette**: `emb_cli` -> Flutter 3.47.5 aus `/home/punky/develop/emb-workspace` -> ivi-homescreen -> Release-AOT. Baue **nie** mit dem `flutter` aus dem PATH (3.41.7) und **nie** in Debug — `executor_lib` schaltet im Debug alle Isolates ab, der Vektormodus laeuft dann auf dem Main-Isolate und jede Beurteilung daraus ist falsch.

Gebaut wird aus dem Worktree `/home/punky/develop/emb-workspace/app/map_local_pi`, damit das Arbeitsverzeichnis unberuehrt bleibt. Es ist ein `git worktree` **desselben** Repos, teilt sich also den Objektspeicher — kein `fetch`, kein zweiter Klon. **Vor dem Bauen auf den zu testenden Stand bringen**, sonst testest du alten Code:

```bash
git -C /home/punky/develop/emb-workspace/app/map_local_pi log --oneline -1   # Stand pruefen
git -C /home/punky/develop/emb-workspace/app/map_local_pi checkout --detach master
```

`--detach` ist noetig: `master` ist im Arbeitsverzeichnis ausgecheckt, und zweimal derselbe Branch geht in Git nicht. Ungespeicherte Aenderungen im Arbeitsverzeichnis sind im Worktree **nicht** sichtbar — was nicht committet ist, wird nicht getestet.

Der Build hinterlaesst im Worktree Spuren: `analysis_options.yaml` (Analyzer-Ausschluesse) und `pubspec.lock` stehen danach als geaendert da, dazu liegen `libapp.so.release` und die Obfuscation-Map herum. Das ist normal und gehoert nicht ins Repo zurueck — nicht committen, nicht "aufraeumen" wollen.

## Erst die Kacheln, sonst ist der Lauf wertlos

Die App sucht einen **festen Dateinamen** `germany.mbtiles` im Datenverzeichnis, die UI bietet keine Dateiauswahl. Der Name sagt nichts ueber die Art der Datei:

- `map/tiles-germany/germany.mbtiles` (154 GB) ist **Raster** (`format=png`). Damit gibt es keinen Vektor-Style, der Style-Chip bewirkt nichts, und die Zeile `Style aktiv` bleibt fuer immer aus.
- Vektor (`format=pbf`): `hessen.mbtiles` (38 GB, deckt trotz des Namens ganz Deutschland ab), `germany-vec.mbtiles` (38 GB), `hessen_extract.mbtiles` (5,4 GB).

Immer zuerst pruefen, nie nach dem Namen gehen:

```bash
sqlite3 "file:<datei>?mode=ro" "select value from metadata where name='format'"
```

Fuer einen Vektorlauf die gewuenschte pbf-Datei unter dem erwarteten Namen verlinken. Das Datenverzeichnis haengt am Embedder:

```bash
# emb/ivi-homescreen-Bundle (beide Wege dieses Skills)
mkdir -p ~/.local/share/homescreen/offline_maps
ln -sfn /home/punky/develop/flutter_local_map/map/tiles-germany/hessen.mbtiles \
        ~/.local/share/homescreen/offline_maps/germany.mbtiles
ln -sfn /home/punky/develop/flutter_local_map/map/tiles-germany/germany_names.db \
        ~/.local/share/homescreen/offline_maps/germany_names.db
```

Ein reiner Flutter-Desktop-Build (nicht dieser Skill) nimmt stattdessen `~/.local/share/com.example.map_local/`, wo die SharedPreferences per `custom_storage_path` auf `map/tiles-germany` zeigen.

---

## Weg 1: lokal

`emb cross --list-targets` zeigt neben den rpi-Eintraegen ein `local  host  (native build)`. Das ist der lokale Weg — gleicher Embedder wie auf dem Pi, nur nativ fuer x86_64.

```bash
cd /home/punky/develop/emb-workspace/app/ivi-homescreen
emb cross . --target local --build \
    --backend wayland-egl \
    --app ../map_local_pi --mode release \
    -D DISABLE_PLUGINS=ON \
    -D BUILD_ACCESSIBILITY=ON -D BUILD_MCP=ON \
    -w /home/punky/develop/emb-workspace
```

Die letzte Zeile der Ausgabe nennt das Ergebnis: `wayland-egl: runnable → <pfad>`. Der Pfad enthaelt einen Hash ueber die Defines, **er aendert sich, wenn du die Defines aenderst** — nicht aus einem frueheren Lauf abschreiben, sondern aus der Ausgabe nehmen.

`-D BUILD_MCP=ON` braucht zwingend `-D BUILD_ACCESSIBILITY=ON` (sonst bricht CMake ab) und ist das, was dich die App spaeter selbst bedienen laesst. Lass es drin.

### Starten

```bash
R=<runnable-pfad>
cd $R && LD_LIBRARY_PATH=$R/lib ./homescreen -b . --enable-mcp -w 1280 --height 720 -t Adwaita
```

Drei Dinge daran sind nicht optional:

- **`LD_LIBRARY_PATH=$R/lib`** — das Bundle findet seine eigene `libsqlite3.so` sonst nicht, obwohl sie dort liegt. Ohne das scheitern MBTiles und Geocoder mit `Failed to load dynamic library 'libsqlite3.so'` und die Karte bleibt leer. Auf dem Pi faellt es nicht auf, weil dort `libsqlite3.so.0` systemweit installiert ist.
- **`-w 1280 --height 720`** — ein Fenster statt Vollbild. Achtung: `-w` heisst beim `homescreen` *width*, beim `emb` dagegen *workspace*. Nicht verwechseln.
- **`--enable-mcp`** — schaltet die Bedienoberflaeche frei (siehe unten).

Starte im tmux und schreibe das Log mit, du brauchst es fuer jede Aussage:

```bash
tmux new-session -d -s hs -x 200 -y 50
tmux send-keys -t hs "cd $R && LD_LIBRARY_PATH=$R/lib ./homescreen -b . --enable-mcp -w 1280 --height 720 -t Adwaita 2>&1 | tee /tmp/hs.log" Enter
```

---

## Weg 2: auf dem Pi

Zugang, Voraussetzungen und die Startbesonderheiten des Geraets stehen in der Memory-Notiz `pi-target-setup` — lies sie, bevor du etwas auf dem Pi anfasst. Das Wichtigste hier:

```bash
cd /home/punky/develop/emb-workspace/app/ivi-homescreen
emb cross . --target rpi4-trixie --build --backend drm-kms-egl \
    --app ../map_local_pi --mode release -D DISABLE_PLUGINS=ON \
    -w /home/punky/develop/emb-workspace

rsync -a --delete <runnable-pfad>/ jeep-pi:~/flutter-sample/
ssh jeep-pi 'cd ~/flutter-sample && ./homescreen -b . -f -t Adwaita'
```

- **`-f` ist Pflicht.** `Size: 1920 x 720` im Log ist der Default der View-Konfiguration, nicht der Scanout-Modus. Ohne `-f` bekommst du ein falsches Bild und misst Unsinn.
- **`-d`** schaltet das Backend-Debuglog dazu. Dann zaehlen `[DrmCompositor] LayerScene commit`-Zeilen — hoeren sie auf, wird nicht mehr gezeichnet (das ist das bekannte Einfrieren, kein Absturz; siehe Memory `pi-freeze-reproduction`).
- **Beenden: `pkill -x homescreen`.** `pkill -f "homescreen -b"` trifft die eigene SSH-Kommandozeile mit und wirft dich aus der Sitzung. Derselbe Fehler passiert lokal genauso.
- **Valhalla laeuft dort nicht** — "Valhalla nicht erreichbar" ist erwartet und kein Befund.
- Das Geraet hat 7,6 GB RAM, die **Zielplattform sind 4 GB**. Speichermessungen entsprechend einordnen.

---

## Die App bedienen, statt den Nutzer klicken zu lassen

Unter WSLg sieht X nichts von den Fenstern, Screenshots von aussen sind schwarz. Der Ausweg ist die MCP-Oberflaeche des Embedders: JSON-RPC 2.0 ueber HTTP auf einem Unix-Socket, gleicher Benutzer, also direkt per `curl` erreichbar.

```bash
SOCK=$XDG_RUNTIME_DIR/ivi-homescreen/mcp.sock
mcp() { curl -s --unix-socket $SOCK -X POST http://localhost/ \
          -H 'Content-Type: application/json' \
          -H 'Accept: application/json, text/event-stream' -d "$1"; }

mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"1"}}}'
mcp '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_snapshot","arguments":{}}}'
mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ui_tap_at","arguments":{"x":1260,"y":28}}}'
```

`ui_snapshot` liefert den Semantikbaum unter `result.content[0].text` als JSON-String (erst `json.loads`, dann `views[].result.nodes` — eine **flache** Knotenliste, nicht verschachtelt). Jeder Knoten bringt `id`, `role`, `label`, `rect` und die erlaubten `actions` mit. Weitere Werkzeuge: `ui_query`, `ui_tap_at`, `ui_set_text`, `ui_scroll_to`, `ui_long_press`.

**Die `id` ist an eine Generation des Baums gebunden.** Jeder Snapshot nennt seine `generation`; sobald die App neu zeichnet, zaehlt sie hoch und alte Nummern sind ungueltig. `ui_tap` antwortet dann mit `no node matched node_id or identifier` — und wenn du die Antwort nicht liest, sieht das aus, als sei die Schaltflaeche kaputt. Bei dieser Karte zeichnet staendig etwas nach, die Nummern halten also keine zwei Sekunden.

Zuverlaessig ist deshalb: Snapshot holen, Knoten **ueber das Label** suchen, Mittelpunkt aus seinem `rect` rechnen und mit **`ui_tap_at`** auf die Koordinate tippen — alles in einem Durchgang. `ui_tap_at` trifft ueber einen Zeigerklick und braucht keine gueltige id. Die Antwort enthaelt `"dispatched":true,"hit_tested":true` — pruefe das, ein Fehlschlag ist sonst stumm.

Zur Orientierung, wie der Baum dieser App aussieht: die beiden Schaltflaechen oben rechts heissen `Optionen` und `Beenden`, der Style-Chip traegt den Dateinamen des aktiven Styles (`style_navigation`), das Modus-Badge `Vektor MBTiles (PBF)`, dazu `Zoom 11.0`, die Suchfelder `Start suchen...` / `Ziel suchen...` und `GPS Sim laden`.

**Die Labels im Baum hinken den Aktionen hinterher.** Ein `ui_query` direkt nach einem `ui_tap` liefert oft noch den alten Zustand. Lies das Ergebnis einer Aktion **aus dem Log**, nie aus dem Baum.

### Woran du erkennst, dass es wirklich laeuft

| Frage | Beleg im Log bzw. Baum |
|---|---|
| Vektor oder Raster? | Modus-Badge im Baum: `Vektor MBTiles (PBF)` |
| Welcher Style gilt? | `[MapError] INFO [<asset>]: Style aktiv: N Ebenen` |
| Karte am richtigen Ort? | **keine** Zeile `[MapError] ERROR [Camera bounds]` |
| Schrift da? | Beschriftung im Bild; fehlt sie komplett, fehlen Systemschriften |

### Wieder rauskommen

Die Demo-App hat oben rechts ein **X** (`Beenden`, daneben `Optionen`) und das Kuerzel **Strg+Q**, beides mit Rueckfrage. Das ist noetig, weil es unter DRM/KMS keinen Fensterrahmen gibt und der Embedder `SystemNavigator.pop` nicht behandelt — auf `flutter/platform` kennt er nur die Zwischenablage. Die App steigt deshalb selbst per `exit(0)` aus.

Das X sitzt in der Demo-App (`lib/main.dart`), **nicht** im Package `local_map` — eine eingebettete Bibliothek darf den Prozess des Gastgebers nicht beenden.

Von aussen bleibt `pkill -x homescreen` (nie `pkill -f`).

Ein Style-Wechsel sieht richtig so aus — der Chip haengt oben rechts und laeuft im Kreis:

```
[MapError] INFO [.../style_navigation.json]: Style aktiv: 20 Ebenen
[MapError] INFO [.../style.json]:            Style aktiv: 12 Ebenen
[MapError] INFO [.../style_second.json]:     Style aktiv: 12 Ebenen
[MapError] INFO [.../style_navigation.json]: Style aktiv: 20 Ebenen
```

Bleibt die Zeile aus, hast du eine Rasterdatei erwischt. Steht dort ein Fallback-Theme, passt der Style nicht zum Schema der Kacheln.

## Wenn es nicht laeuft

| Symptom | Ursache |
|---|---|
| `Failed to load dynamic library 'libsqlite3.so'` | `LD_LIBRARY_PATH=<runnable>/lib` vergessen |
| Karte leer, keine `Style aktiv`-Zeile | Rasterdatei statt pbf |
| Karte leer, `ERROR [Camera bounds]` im Log | Kachelabdeckung und Startposition passen nicht zusammen |
| Karte ohne jede Beschriftung | keine Systemschriften (`fonts-dejavu-core`) |
| Unsichtbarer Mauszeiger, `[DrmCursor] no XCursor theme found` | `adwaita-icon-theme` fehlt, Start ohne `-t Adwaita` |
| Start haengt ueber SSH ohne Fehler | `seatd` nicht aktiv (nur Pi, `drm-kms-egl`) |
| SSH-Sitzung bricht beim Beenden ab | `pkill -f` statt `pkill -x` |
| Ruckeln "gemessen" | Debug-Build oder Wanduhr statt `addTimingsCallback` |

Tiefergehendes Pruefverfahren (Pixelmessung mit Referenzwerten, GPS-Route als Last, Offline-Nachweis per Netzwerk-Namespace) steht in der Memory-Notiz `map-verification-harness`.
