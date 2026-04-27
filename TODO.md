# TODO - Offline-Karten (flutter_map)

## P0 - Muss sofort
- [ ] Non-Regression: Raster-MBTiles-Unterstützung muss erhalten bleiben
  - Lesen von Raster-MBTiles (png/jpg/jpeg/webp) darf durch Offline-Refactoring nicht beeinträchtigt werden.
  - Anzeige von Raster-MBTiles im `TileLayer` muss unverändert funktionieren.
  - Keine Änderung am Format-Fallback-Verhalten: unbekannte Formate weiterhin mit klarer Fehlermeldung.

- [x] Remote-Style-Loading komplett entfernen
  - In [lib/widgets/map_view.dart](lib/widgets/map_view.dart) alle URL-basierten Style-Aufrufe löschen.
  - `_defaultVectorStyleUri` entfernen.
  - Kein Netzwerkzugriff mehr im Karten-Init.

- [x] Lokalen Asset-Style als Primärstil setzen
  - Primär: `assets/maps/style.json`
  - Fallback nur bei Fehler: `vtr.ProvidedThemes.lightTheme()`
  - Bug fixen: Nach erfolgreichem `ThemeReader` nicht auf `lightTheme()` überschreiben.

- [x] Vector Source-Mapping robust machen
  - Sources aus lokalem Style ableiten.
  - Nur notwendige Aliase ergänzen.
  - Leeres Source-Mapping verhindern.

## P1 - Hoch
- [ ] Fehlerbehandlung für Offline-Betrieb verbessern
  - Fehlerklassen: Asset fehlt, JSON ungültig, keine Sources, MBTiles-Format unbekannt.
  - Nutzerfreundliche Meldungen + technische Debug-Logs.

- [ ] Async-Race-Schutz beim MBTiles-Wechsel
  - Request-Token/Generation einführen.
  - Veraltete async-Resultate ignorieren.
  - Keine `setState`-Aufrufe aus alten Requests.

## P2 - Mittel
- [ ] Rebuilds bei Zoom reduzieren
  - Zoom-Badge entkoppeln.
  - Karten-Rebuilds minimieren.
  - Funktionalität unverändert halten.

- [ ] Offline-Smoke-Testmatrix dokumentieren und ausführen
  - pbf + gültiger Asset-Style
  - pbf + kaputter Asset-Style (Fallback)
  - raster-MBTiles (Lesen + Anzeige im `TileLayer`)
  - defekte/fehlende metadata
  - Ergebnisse protokollieren.

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
- [ ] In [lib/widgets/map_view.dart](lib/widgets/map_view.dart) Kartenkern von Renderer-spezifischer Tile/Style-Logik trennen.
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
