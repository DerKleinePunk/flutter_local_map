# TODO - Offline-Karten (flutter_map)

## Stand 2026-09-22

### Was sich geaendert hat

- Die Karte liegt als eigenstaendiges Package unter
  [packages/local_map/](packages/local_map/). Die App im Root ist Demo und
  Referenz. Einbindung in andere Projekte: siehe
  [packages/local_map/README.md](packages/local_map/README.md).
- **Der Vektormodus funktioniert.** Die Ursache der leeren Karte war ein
  Umrechnungsfehler im NMEA-Parser (Teiler 1000 statt 100 beim Laengengrad),
  der die Kamera auf 15,36 statt 9,36 Grad Ost schickte - also aus der
  Abdeckung von `hessen.mbtiles` heraus (Ostgrenze 15,05). Commit `1a3f14a`.
- `vector_map_tiles` kommt wieder von pub.dev (9.0.0-beta.13), der eigene
  Fork ist abgeloest. Es bleiben zwei Git-Overrides.

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

- [ ] **Touch-Eingabe funktioniert nicht.** Das Sample wird angezeigt, aber
      Beruehrungen kommen nicht an. Eingabe laeuft im Embedder ueber libinput,
      unabhaengig von `DISABLE_PLUGINS`. Zu pruefen: `libinput list-devices`
      auf dem Pi, Rechte auf `/dev/input/event*` (User `pi` ist in Gruppe
      `input`), ob seatd die Eingabegeraete durchreicht.
- [ ] **Karte auf dem Pi visuell bestaetigen.** Die App oeffnet die MBTiles
      dort nachweislich, ob die Karte gezeichnet wird, wurde noch nicht mit
      Augen geprueft - zuletzt lief das Sample auf dem Schirm, nicht die App.
- [x] **`logError` aus der `kDebugMode`-Sperre genommen.** In
      [map_error_handler.dart](packages/local_map/lib/src/services/map_error_handler.dart)
      loggt `_logError` jetzt immer, `logDebug` bleibt auf Debug beschraenkt.
      `classifyUnsupportedFormat` laeuft ueber denselben Pfad statt ueber einen
      eigenen Debug-Block. Damit meldet sich die Karte auf dem Pi auch im
      Release, wenn Style, MBTiles oder SQLite Aerger machen.
- [ ] **Bildgroesse pruefen.** ivi-homescreen meldet `Size: 1920 x 720`, das ist
      sein Standardwert und nicht die Monitoraufloesung.
- [ ] **Messharness fuer den Pi bauen**, um echte Frame-Zeiten vom Zielgeraet
      zu bekommen statt der WSL2-Zahlen mit defektem GPU-Stack.

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
- [ ] **Auf dem echten Pi gegenmessen.** Alle Zahlen oben stammen von WSL2
      mit defektem GPU-Stack und sind dort vermutlich eher pessimistisch -
      das ist aber eine Vermutung. Verfahren steht im
      [README](README.md#vektorkarte-ruckelt-oder-friert-ein).
- [ ] **Upstream-PR fuer die beiden verbliebenen Forks.** Sie existieren nur,
      weil die pub.dev-Versionen an `mbtiles ^0.4.0` haengen (und
      `vector_map_tiles_mbtiles` zusaetzlich an `vector_map_tiles ^8.0.0`).
      Letzte Veroeffentlichung dort: September 2024.
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
  `test/`, die 17 Tests des Pakets brauchen `flutter test` in
  [packages/local_map/](packages/local_map/).
- **`test/offline_smoke_test_matrix.dart` laeuft nie mit.** Der Dateiname endet
  nicht auf `_test.dart`, `flutter test` sammelt sie also nicht ein - die
  "12 Tests gruen" unter P2 sind seit dem Umbau unbelegt.

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
  - ✅ Alle 12 Tests grün (test/offline_smoke_test_matrix.dart)

## Definition of Done
- [ ] Kein Codepfad lädt Styles aus dem Netz.
- [ ] Karte funktioniert vollständig offline.
- [ ] Lokaler Style wird genutzt, Fallback greift nur bei Fehlern.
- [ ] Raster-MBTiles werden weiterhin korrekt gelesen und angezeigt.
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
