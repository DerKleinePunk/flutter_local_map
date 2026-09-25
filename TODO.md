# TODO - Offline-Karten (flutter_map)

## Stand 2026-09-25

Den Stand der Einbindung in Carnine2 fuehrt
[docs/plan-carnine2-integration.md](docs/plan-carnine2-integration.md), die
Aenderungen an der Bibliothek
[packages/local_map/CHANGELOG.md](packages/local_map/CHANGELOG.md) (zuletzt
`local_map-v0.4.1`). Hier stehen die offenen Punkte der Karte selbst.

### Was sich geaendert hat (bis 2026-09-22)

- Die Karte liegt als eigenstaendiges Package unter
  [packages/local_map/](packages/local_map/). Die App im Root ist Demo und
  Referenz. Einbindung in andere Projekte: siehe
  [packages/local_map/README.md](packages/local_map/README.md).
- **Der Vektormodus funktioniert.** Die Ursache der leeren Karte war ein
  Umrechnungsfehler im NMEA-Parser (Teiler 1000 statt 100 beim Laengengrad),
  der die Kamera auf 15,36 statt 9,36 Grad Ost schickte - also aus der
  Abdeckung von `hessen.mbtiles` heraus (Ostgrenze 15,05). Commit `1a3f14a`.
- `vector_map_tiles` kommt aus einem neuen Fork: upstream 9.0.0-beta.13 plus
  ein Commit, der `panBuffer` und `rasterTileScale` einstellbar macht (Branch
  `local_map_pi`, seit `ba06454`). Der alte Fork zum Cancellation-Handling
  ist abgeloest. Es sind wieder **drei** Git-Overrides.

Gemessen (Release, GPS-Route bei Zoom 17, offline im Netzwerk-Namespace):
alle Kacheln sichtbar, 422 MB RSS, schlechtester Frame 86 ms Build +
118 ms Raster.

### Pi-Portierung (Stand 2026-09-22 abends)

Die App laeuft cross-compiliert auf dem Test-Pi. Kette: `emb_cli` 0.3.6 ->
Flutter 3.47.5 -> vorgebaute arm64-Engine -> ivi-homescreen (Backend
`drm-kms-egl`) -> Bundle -> rsync auf den Pi. Workspace liegt ausserhalb des
Repos unter `/home/punky/develop/emb-workspace`, gebaut wird aus einem
`git worktree`, damit dieses Arbeitsverzeichnis unberuehrt bleibt.

Bestaetigt: **Bild kommt auf dem Monitor an** (Flutter-Sample sichtbar),
60 Hz, Direct-Scanout, vc4. `libsqlite3.so` im Bundle ist korrektes aarch64 -
die `FLUTTER_HOOK_CC`-Warnung von emb trifft uns nicht, weil `sqlite3` seine
Bibliothek vorgebaut herunterlaedt statt zu kompilieren.

- [x] **Karte auf dem Pi visuell bestaetigt** (2026-09-22). Die Karte wird
      gezeichnet. Sie war vorher leer, weil die Datei
      `~/.local/share/homescreen/offline_maps/germany.mbtiles` in Wahrheit
      `braunschweig.mbtiles` ist (gleiche Groesse, Bounds 10,28-10,78 O /
      52,12-52,42 N), die Kamera aber auf Alsfeld startet. Seit `23dda12`
      rueckt die Kamera in die Abdeckung und sagt es im Log.
- [x] **Schriftart auf dem Pi nachinstalliert** (`fonts-dejavu-core`).
      `/usr/share/fonts` existierte dort nicht - ohne Schrift zeichnet Skia
      keinen Buchstaben, deshalb fehlte jede Kartenbeschriftung, ohne
      Fehlermeldung. Dokumentiert in [README.md](README.md) und
      [packages/local_map/README.md](packages/local_map/README.md), damit es
      nicht jeder neu sucht, der mit `emb_cli` baut.
- [x] **Cursor-Theme nachinstalliert** (`adwaita-icon-theme`, Start mit
      `-t Adwaita`). Der Embedder meldet jetzt
      `[DrmCursor] ready (sprite=24px ...)` statt `no XCursor theme found`.
- [ ] **Schrift ins Bundle nehmen statt aufs System zu vertrauen.** Fuer ein
      Kiosk-Image ist eine Schrift als Flutter-Asset (`fonts:` in der
      pubspec plus `ThemeData.fontFamily`) robuster als ein apt-Paket, das
      beim naechsten Image wieder fehlt.
- [ ] **Es haengt kein Touchscreen am Pi.** Einzige Zeigereingabe ist das
      Touchpad der Riitek-Funktastatur (`/dev/input/event1`, relative Maus).
      Bevor jemand weiter "Touch" sucht: das Geraet, das getestet werden
      soll, muss erst angeschlossen sein.
- [x] **Valhalla laeuft auf dem Pi** (2026-09-24): 3.9.0 als systemd-Dienst
      auf `127.0.0.1:8002`, auf beiden Pis. Einzelheiten in
      [docs/valhalla-offline-setup.md](docs/valhalla-offline-setup.md#stand-auf-den-test-pis).
- [x] **`logError` aus der `kDebugMode`-Sperre genommen.** In
      [map_error_handler.dart](packages/local_map/lib/src/services/map_error_handler.dart)
      loggt `_logError` jetzt immer, `logDebug` bleibt auf Debug beschraenkt.
      `classifyUnsupportedFormat` laeuft ueber denselben Pfad statt ueber einen
      eigenen Debug-Block. Damit meldet sich die Karte auf dem Pi auch im
      Release, wenn Style, MBTiles oder SQLite Aerger machen.
- [x] **Bildgroesse geklaert.** `Size: 1920 x 720` ist der Default der
      View-Konfiguration, nicht der Scanout-Modus. Der Monitor (Lenovo
      L1950wD an HDMI-A-1) kann 1920x1080@60. Mit `-f` meldet der Embedder
      `1920x1080 logical -> 1920x1080 px, pixel_ratio=1`. Also immer mit
      `-f` starten oder `-w/--height` setzen; `--drm-list-modes` listet die
      Modi des Geraets.
- [x] **1024x600 laeuft unter Full-KMS** (2026-09-22). `vc4-fkms-v3d` wird
      nicht gebraucht. Das Panel bringt ein geklontes EDID mit ungeraden
      horizontalen Timings mit, die der vc4-Treiber ablehnt; ein korrigiertes
      EDID per `drm.edid_firmware` loest es. Verfahren und Begruendung:
      [docs/waveshare-1024x600-full-kms.md](docs/waveshare-1024x600-full-kms.md).
- [x] **Touch-Eingabe funktioniert** (2026-09-22). Das Panel war schlicht nicht
      angeschlossen. Angesteckt meldet es sich als `STMicroelectronics 7H
      Custom Human interface` (`0484:5750`) mit `INPUT_PROP_DIRECT`,
      Multitouch und `BTN_TOUCH` auf `/dev/input/event8`; ein Mitschnitt am
      Kernel zeigte saubere Koordinaten. Am Embedder war nichts zu tun.
- [x] **Richtige Kartendaten auf dem Pi** (2026-09-22). Statt des
      Braunschweig-Ausschnitts liegt dort jetzt ein Hessen-Ausschnitt aus
      `germany-vec.mbtiles` (Grenzen wie `MapConfig.hessenBounds`, z4-17,
      1.553.711 Kacheln, 5,31 GB) plus `germany_names.db` fuer die Suche.
      Die Standard-Startposition (Alsfeld) liegt darin, die Kamerakorrektur
      meldet sich also nicht mehr - das leere Log ist der Nachweis. Gebaut in
      54 s, uebertragen in 70 s bei rund 77 MB/s.
- [x] **Die App wird nach einiger Laufzeit blind und stumm.** Erledigt
      (2026-09-24): Dauertest auf carnine-pc 3 h 22 min Karte am Stueck, nie
      eingefroren, 0 verlorene Page-Flips, ~56 fps, RSS 160 MB; auf jeep-pi
      seither ebenfalls nicht mehr aufgetreten. Die Eingrenzung bleibt hier
      stehen, falls es wiederkommt: Auf dem Pi
      bleibt das Bild irgendwann stehen und Beruehrungen bewirken nichts
      mehr. Am 2026-09-23 eingekreist:
      - Kein Absturz: der Prozess lebt, alle Threads schlafen regulaer, kein
        OOM, keine Fehlerzeile.
      - Nicht das Panel: `libinput debug-events` liefert `TOUCH_DOWN` /
        `TOUCH_MOTION` weiterhin sauber auf `seat0`.
      - Nicht die Sitzung: keine Suspend- oder VT-Zeile im Log, VT bleibt 1.
      - Nicht USB-Stromsparen: `power/control=on`, nie suspendiert.
      - Die Bildschaltungen (`LayerScene commit`) hoeren schlagartig auf und
        kommen nie wieder. Ein Neustart behebt es sofort.
      **Reproduktion ohne Bediener:** ein virtuelles Touchgeraet per `uinput`
      anlegen und eine Wischgeste erzeugen, dann `LayerScene commit` im Log
      zaehlen. Frisch gestartet ergibt das rund 45 neue Schaltungen, im
      haengenden Zustand null. Skript lag als `/tmp/fake_touch.py` auf dem Pi.
      **Naechster Verdacht:** verlorene Page-Flip-Ereignisse. Der Embedder
      meldet genau das selbst:
      `WaitForPendingFlip: no flip completion after 100ms; proceeding
      (PAGE_FLIP_EVENT likely lost)`. Bleibt eine Flip-Antwort aus, bekommt
      die Engine keinen Vsync mehr und zeichnet nie wieder - Eingaben werden
      dabei weiter verarbeitet (CPU steigt), nur sichtbar wird nichts.
      Gegenprobe waere `--drm-pipeline-depth 2` oder `--drm-async-flip no`.
- [x] **Messharness fuer den Pi** (2026-09-23): der Messlauf
      `LOCAL_MAP_BENCH` der Demo-App ([lib/map_bench.dart](lib/map_bench.dart),
      Aufruf im [README](README.md#messlauf-fuer-die-ladezeit)) misst die
      Ladezeit und die Frame-Zeiten im Release direkt auf dem Pi. Damit
      entstanden `panBuffer 0`, `rasterTileScale` und das eigene
      tilemaker-Lua: Start 5 s -> 1,9 s, Frankfurt z14 17-19 s -> 9 s,
      z8 16-17 s -> 3,4-3,8 s.

### Offen

- [ ] **MapLibre-Migration neu bewerten, bevor jemand anfaengt.** Der Plan
      weiter unten (Phase 1-5, 8-13 Tage) entstand, weil der Vektormodus
      unbrauchbar schien. Diese Annahme ist widerlegt. Vor einem Start also
      klaeren, welches Problem MapLibre jetzt noch loesen soll.
- [ ] **`sqlite3_flutter_libs` aus dem eigenen Fork werfen.** Das Paket ist
      seit 0.6.0+eol (Februar 2026) tot: "Not used anymore, update to version
      3.x of package:sqlite3 instead". Es haengt nur noch transitiv drin, weil
      `flutter_map_mbtiles` es in seiner pubspec listet. Eine Zeile in
      https://github.com/DerKleinePunk/flutter_map_plugins (Branch
      `to_flutter_map_8`). Danach faellt `libsqlite3_flutter_libs_plugin.so`
      aus dem Bundle.
- [ ] **Flutter-SDK anheben.** 3.41.7 (April 2026) blockiert rund 30 Pakete,
      darunter `sqlite3` 3.6.0 (braucht `hooks ^2.2.0`) sowie
      `sqflite_common_ffi` 2.4.3 und `sqflite_common` 2.5.13 (brauchen
      Dart ^3.12). Betrifft auch die Pi-Cross-Compile-Kette.
- [ ] **Raster-Kachelnaehte.** Beim serverseitig gerenderten Raster werden
      Labels an Kachelgrenzen abgeschnitten ("Ermenrod" endet mitten im
      Wort), weil tileserver-gl jede Kachel isoliert rendert. Fix ist
      `config["options"]["tileMargin"]` in
      [scripts/render_raster.py](scripts/render_raster.py) neben den
      bestehenden `maxRendererPoolSizes` - eine Zeile, aber ein Neu-Rendern
      der 154 GB. Vorher klaeren, ob die Raster-Pipeline ueberhaupt noch
      gebraucht wird, jetzt wo Vektor laeuft.
- [x] **Auf dem echten Pi gegenmessen.** Ladezeiten gemessen (siehe
      Messharness oben). Offen bleibt die Speichermessung gegen 4 GB mit
      Valhalla, Karte und Medienwiedergabe gleichzeitig - die gehoert zu
      Phase 5 im [Carnine2-Plan](docs/plan-carnine2-integration.md).
- [ ] **Upstream-PRs fuer die drei Forks.** Die beiden aus
      `flutter_map_plugins` existieren nur, weil die pub.dev-Versionen an
      `mbtiles ^0.4.0` haengen (und `vector_map_tiles_mbtiles` zusaetzlich an
      `vector_map_tiles ^8.0.0`); letzte Veroeffentlichung dort: September
      2024. Der `vector_map_tiles`-Fork ist ein einzelner Commit
      (`panBuffer`, `rasterTileScale` einstellbar) und taugt als PR an
      upstream.
- [ ] **`jni` im Linux-Build beobachten.** Kam mit dem Upgrade von
      `path_provider_android` neu herein und landet als `libdartjni.so` im
      Bundle. Baut hier durch; falls die Pi-Kette stolpert,
      `path_provider_android` per Override unter 2.3.1 halten.

### Bekannte Stolperfallen

- **Vektorperformance nie im Debug messen.** `executor_lib` liefert
  `kDebugMode ? QueueExecutor() : PoolExecutor(...)` - im Debug laufen Parsen
  und Rendern aller Kacheln auf dem Main-Isolate.
- **Wanduhr-Abstaende sind kein Jank-Mass.** Unter WSL2/WSLg zeigt eine leere
  Flutter-App ohne Karte Aussetzer bis 24 s. Nur
  `SchedulerBinding.instance.addTimingsCallback` ist aussagekraeftig.
- **Eine leere Karte ist meist ein Koordinatenproblem**, kein Renderfehler.
  Zuerst pruefen, ob die Kameraposition in den `bounds` der MBTiles liegt.
- **Tests liegen an zwei Orten.** `flutter test` im Repo-Root findet nur
  `test/`, die Tests des Pakets brauchen `flutter test` in
  [packages/local_map/](packages/local_map/).
- **Zoom-Gesten auf kleinen Ausschnitten.** `flutter_map` verankert den Zoom
  ab Werk am Brennpunkt der Geste (`pinchMove`) bzw. am Mauszeiger. Auf einer
  Weltkarte ist das richtig, auf einem 34 km breiten Ausschnitt schiebt ein
  Griff neben die Bildmitte die Kacheln aus dem Bild - bei Zoom 11 sind
  320 px rund 11 km. In der Karte ist `pinchMove` deshalb aus, ebenso das
  Drehen. Belegt in
  [pinch_gesture_test.dart](packages/local_map/test/pinch_gesture_test.dart).
- **Eingabegeraete nie ueber `/dev/input/eventN` ansprechen.** Die Nummern
  verschieben sich bei Neustart und Umstecken - der Touchscreen lag erst auf
  `event8`, spaeter auf `event4`, und `event8` war dann der HDMI-Audioanschluss.
  Stabil ist nur der Pfad unter `/dev/input/by-id/`.
- **RaspiOS Lite bringt weder Fonts noch Cursor-Themes mit.** Ohne
  `/usr/share/fonts` zeichnet Skia keinen Buchstaben, ohne XCursor-Theme gibt
  es keinen Mauszeiger. Beides sieht auf den ersten Blick nach einem
  Renderfehler bzw. nach toter Eingabe aus.
- **Der Pi startet die App im Vollbild nur mit `-f`.** Sonst laeuft die View
  mit 1920x720 in einem 1920x1080-Scanout.
- **Testdateien muessen auf `_test.dart` enden**, sonst sammelt `flutter test`
  sie nicht ein. Die Smoke-Matrix hiess `offline_smoke_test_matrix.dart` und
  lief deshalb lange nicht mit; unbemerkt veraltete dabei eine Erwartung
  (deutsche Fehlermeldung, seit 0.3.0 englisch). Seit 2026-09-25 heisst sie
  `offline_smoke_matrix_test.dart` und ist gruen. Die Tests im Root brauchen
  die echten MBTiles unter `map/tiles-germany/`.

## P0 - Muss sofort
- [x] Non-Regression: Raster-MBTiles-Unterstützung muss erhalten bleiben
  - ✅ Lesen von Raster-MBTiles (png/jpg/jpeg/webp) funktioniert, Metadaten-Abfrage ok
  - ✅ Anzeige von Raster-MBTiles im `TileLayer` funktioniert unverändert
  - ✅ Format-Erkennung und Fallback-Verhalten validiert durch test/mbtiles_regression_test.dart

- [x] Remote-Style-Loading komplett entfernen
  - In [packages/local_map/lib/src/widgets/map_view.dart](packages/local_map/lib/src/widgets/map_view.dart) alle URL-basierten Style-Aufrufe löschen.
  - `_defaultVectorStyleUri` entfernen.
  - Kein Netzwerkzugriff mehr im Karten-Init.

- [x] Lokalen Asset-Style als Primärstil setzen
  - Primär: `packages/local_map/assets/maps/style.json`
  - Fallback nur bei Fehler: `vtr.ProvidedThemes.lightTheme()`
  - Bug fixen: Nach erfolgreichem `ThemeReader` nicht auf `lightTheme()` überschreiben.

- [x] Vector Source-Mapping robust machen
  - Sources aus lokalem Style ableiten.
  - Nur notwendige Aliase ergänzen.
  - Leeres Source-Mapping verhindern.

## P1 - Hoch
- [x] Fehlerbehandlung für Offline-Betrieb verbessern
  - ✅ Fehlerklassifizierung implementiert (MapErrorHandler.classify)
  - ✅ Nutzerfreundliche Meldungen + technische Debug-Logs
  - ✅ Fehlerklassen: AssetMissing, JsonInvalid, SqliteError, StyleMissingSource, etc.
  - ✅ MbTilesException für strukturierte Fehlerbehandlung
  - ✅ Tests validieren Fehlerklassifizierung (test/map_error_handler_test.dart)

- [x] Async-Race-Schutz beim MBTiles-Wechsel
  - ✅ Request-Token/Generation eingeführt (_initializationToken)
  - ✅ Token inkrementiert bei jedem _initializeTileProvider Call
  - ✅ Token-Check vor jedem setState verhindert stale Updates
  - ✅ Tests validieren Token-basierte Deduplication (test/map_view_race_prevention_test.dart)

## P2 - Mittel
- [x] Rebuilds bei Zoom reduzieren
  - ✅ ValueNotifier<double> für Zoom-State eingeführt
  - ✅ onPositionChanged nur ValueNotifier aktualisieren (kein setState)
  - ✅ Separates _ZoomBadgeWidget mit ValueListenableBuilder
  - ✅ Badge updates unabhängig von Map-Rebuilds

- [x] Offline-Smoke-Testmatrix dokumentieren und ausführen
  - ✅ 7 Szenarien dokumentiert und implementiert
  - ✅ Szenario 1: Vector MBTiles (pbf) + valid style
  - ✅ Szenario 2: Raster MBTiles (png/jpg/webp) + Zoom Bounds
  - ✅ Szenario 3: Error handling - missing files
  - ✅ Szenario 4: Error handling - corrupted metadata
  - ✅ Szenario 5: Format validation (accepted/rejected)
  - ✅ Szenario 6: Concurrent access patterns
  - ✅ Szenario 7: Metadata completeness
  - ✅ Alle 12 Tests grün (test/offline_smoke_matrix_test.dart, wieder belegt am 2026-09-25)

## Definition of Done
- [x] Kein Codepfad lädt Styles aus dem Netz.
- [x] Karte funktioniert vollständig offline (nachgewiesen im
      Netzwerk-Namespace, einziger Zugriff ist Valhalla auf `127.0.0.1`).
- [x] Lokaler Style wird genutzt, Fallback greift nur bei Fehlern.
- [x] Raster-MBTiles werden weiterhin korrekt gelesen und angezeigt.
- [ ] `flutter analyze` ohne neue Issues.

## MapLibre-Migrationsplan (April 2026)

### Ziel
- [ ] MapLibre als bevorzugten Renderer evaluieren und bei positivem Ergebnis produktiv nutzen.
- [ ] Bestehende Offline-Funktionen (Suche, Routing, GPS-Sim, Download) ohne Regression erhalten.

### Phase 0 - Baseline und KPIs (0,5 Tag)
- [ ] Vergleichs-KPIs festlegen: Startzeit, RAM-Spitze, Zoom/Pan-Reaktionszeit, Paketgroesse, Tile-Build-Zeit.
- [ ] Baseline mit aktuellem Renderer aufnehmen und protokollieren.

### Phase 1 - Architektur entkoppeln (1-2 Tage)
- [ ] In [packages/local_map/lib/src/widgets/map_view.dart](packages/local_map/lib/src/widgets/map_view.dart) Kartenkern von Renderer-spezifischer Tile/Style-Logik trennen.
- [ ] Kartenkern stabil halten: Suche, Routing, GPS-Simulation, Badges, Kamera-Handling.
- [ ] Zielzustand: Renderer austauschbar, ohne Business-Logik anzufassen.

### Phase 2 - MapLibre parallel integrieren (2-4 Tage)
- [ ] MapLibre-Dependency in [pubspec.yaml](pubspec.yaml) als zweiter Renderer aufnehmen.
- [ ] Feature-Flag/Umschalter einfuehren, damit FlutterMap und MapLibre parallel testbar sind.
- [ ] Offline-Style-Assets fuer MapLibre vorbereiten: Style JSON, Glyphs, Sprites, MBTiles-Verknuepfung.

### Phase 3 - End-to-End Smoke-Tests (1-2 Tage)
- [ ] Offline-Start ohne Netzwerk auf allen Zielplattformen pruefen.
- [ ] Kernfunktionen gegenpruefen: Suche, Marker, Routing, GPS-Sim, Style-Wechsel.
- [ ] Fehler nach Schweregrad klassifizieren (Blocker/Major/Minor) und Blocker zuerst beheben.

### Phase 4 - KPI-Vergleich und Entscheidung (2 Tage)
- [ ] FlutterMap vs. MapLibre mit identischen Daten/Teststrecken benchmarken.
- [ ] Bewertungsraster anwenden: Vektorqualitaet, Performance, Stabilitaet, Betriebsaufwand.
- [ ] Go/No-Go dokumentieren und im Team abnehmen.

### Phase 5 - Rollout und Aufraeumen (1-2 Tage)
- [ ] Bei Go: MapLibre als Standard setzen, FlutterMap initial als Fallback beibehalten.
- [ ] Nicht mehr benoetigte Pfade nach erfolgreicher Stabilisierung entfernen.
- [ ] Abschluss-Regression und Release-Kandidat bauen.

### Abnahmekriterien
- [ ] Offline-Start ist stabil und reproduzierbar.
- [ ] Keine Regression in Suche, Routing und GPS-Simulation.
- [ ] MapLibre zeigt bei Vektor-Rendering messbar gleichen oder besseren Betrieb.
