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

- [ ] Vector Source-Mapping robust machen
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
