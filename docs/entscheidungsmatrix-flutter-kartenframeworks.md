# Entscheidungsmatrix: Flutter-Kartenframeworks

Stand: 2026-04-05

## Vergleich

| Kriterium | flutter_map | maplibre_gl | mapbox_maps_flutter | google_maps_flutter | flutter_osm_plugin |
|---|---|---|---|---|---|
| Offline mit MBTiles | Sehr gut | Gut (mehr Setup) | Gut | Eher begrenzt/anderes Modell | Eher begrenzt |
| Vektor-Styles (Style-JSON, Layer tief) | Mittel bis gut | Sehr gut | Sehr gut | Mittel | Niedrig bis mittel |
| Vendor-Lock-in | Nein | Nein | Ja (Mapbox) | Ja (Google) | Nein |
| Kostenmodell | Frei (abh. von Tile-Quelle) | Frei (abh. von Tile-Quelle) | Token + Tarifmodell | API-Key + Tarifmodell | Frei (abh. von Tile-Quelle) |
| Plattform-Fit für Desktop/Windows | Gut mit Flutter-Ökosystem | Fokus mobile/web | Laut Repo kein Desktop/Web | Primär mobile | Primär mobile/web |
| Aufwand im Projekt | Sehr gering | Mittel bis hoch | Mittel bis hoch | Mittel | Mittel |
| Passend zum aktuellen Code | Sehr hoch | Mittel | Niedrig bis mittel | Niedrig | Niedrig |

## Empfehlung für dieses Projekt

1. Beste Wahl aktuell: `flutter_map`
2. Begründung: Bereits im Code integriert, MBTiles-Offline-Use-Case passt sehr gut.
3. Alternative bei höherem Styling-Bedarf: `maplibre_gl`.
4. Proprietäre Optionen (`Mapbox`/`Google`) nur wählen, wenn bewusst deren Ökosystem, APIs und Kostenmodell gewünscht sind.

## Entscheidung

- Primärframework: `flutter_map`
- Architekturprinzip: Offline-first, lokale MBTiles und lokaler Style als Standard
- Nicht-Ziel: Abhängigkeit von remote Styles oder zwingenden Vendor-Backends
