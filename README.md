# Offline-Karte Hessen - Flutter Desktop App

Flutter-Desktop-Anwendung zur Darstellung von Offline-Kartendaten für die Region Hessen mit lokalen MBTiles-Dateien.

## 📋 Übersicht

Diese Anwendung nutzt `flutter_map` zur Darstellung von OpenStreetMap-Kartendaten, die lokal als MBTiles-Datei gespeichert werden. Die Kartendaten werden während des CI/CD-Prozesses (Azure DevOps) aus Online-Quellen generiert und können von der App nachträglich heruntergeladen werden.

### Features

- ✨ Offline-Kartendarstellung für Hessen
- 📦 MBTiles-basierte Kartenspeicherung (kompakt, einzelne Datei)
- ⬇️ Nachträglicher Download der Kartendaten (kleinere App-Größe)
- 🖥️ Windows und Linux Desktop-Support
- 🗺️ Zoom-Level 10-14 (optimale Balance zwischen Detail und Dateigröße)
- 🔒 Geografische Begrenzung auf Hessen-Region
- 📊 Download-Progress-Anzeige

## 🚀 Quick Start

### Voraussetzungen

- Flutter SDK 3.11.4 oder höher
- Windows oder Linux Desktop-Umgebung
- Python 3.12+ und `pip` (nur für Tile-Generierung im CI/CD)

### Installation

1. **Repository klonen**
   ```bash
   git clone <repository-url>
   cd map_local
   ```

2. **Dependencies installieren**
   ```bash
   flutter pub get
   ```

3. **Anwendung starten**
   ```bash
   # Für Windows
   flutter run -d windows

   # Für Linux
   flutter run -d linux
   ```

### Erste Schritte

1. Beim ersten Start zeigt die App einen Download-Dialog an
2. Klicken Sie auf "Jetzt herunterladen", um die Kartendaten (~250 MB) zu laden
3. Nach Abschluss des Downloads wird die Karte automatisch angezeigt

## 📁 Projektstruktur

```
map_local/
├── lib/
│   ├── config/
│   │   └── map_config.dart          # Konfiguration (Bounding Box, URLs, etc.)
│   ├── services/
│   │   └── map_downloader.dart      # Download-Manager für MBTiles
│   ├── widgets/
│   │   ├── map_view.dart            # Map-Display-Widget
│   │   └── download_overlay.dart    # Download-UI
│   └── main.dart                    # Haupt-App
├── scripts/
│   └── download_tiles.py            # Python-Script für Tile-Generierung
├── azure-pipelines.yml              # Azure DevOps Pipeline
├── assets/
│   └── maps/                        # Verzeichnis für MBTiles-Dateien
└── pubspec.yaml                     # Dependencies
```

## 🔧 Konfiguration

### Kartendaten anpassen

Bearbeiten Sie `lib/config/map_config.dart`, um folgende Einstellungen zu ändern:

```dart
class MapConfig {
  // Bounding Box für angezeigte Region
  static const double northLat = 51.6569;
  static const double southLat = 49.3963;
  static const double eastLng = 10.2358;
  static const double westLng = 7.7726;

  // Zoom-Level Einstellungen
  static const int minZoom = 10;
  static const int maxZoom = 14;

  // Download-URL (nach Azure Pipeline-Setup)
  static const String downloadUrl = 'https://...';
}
```

### Download-URL aktualisieren

Nach dem ersten erfolgreichen Build in Azure DevOps:

1. Navigieren Sie zu Ihrem Azure DevOps-Projekt
2. Öffnen Sie den erfolgreichen Build
3. Laden Sie die Artifact-URL (oder veröffentlichen Sie in Azure Blob Storage)
4. Aktualisieren Sie `MapConfig.downloadUrl` in `map_config.dart`

## 🏗️ Build-Prozess

### Lokaler Build

```bash
# Windows Release-Build
flutter build windows --release

# Linux Release-Build
flutter build linux --release
```

Die ausführbaren Dateien befinden sich in:
- Windows: `build/windows/x64/runner/Release/`
- Linux: `build/linux/x64/release/bundle/`

### Azure DevOps CI/CD Pipeline

Die Pipeline lädt automatisch OpenStreetMap-Tiles herunter und erstellt die MBTiles-Datei.

#### Pipeline-Setup

1. **Repository in Azure DevOps verbinden**
2. **Neue Pipeline erstellen**
   - Wählen Sie `azure-pipelines.yml` als Konfiguration
3. **Pipeline ausführen**
   - Manuell über "Run pipeline" oder automatisch bei Push zu `main`

#### Pipeline-Ausgabe

Nach erfolgreichem Build:
- Artifact: `map-tiles`
- Datei: `hessen.mbtiles`
- Größe: ~150-300 MB

#### Artifact-Download-URL

```
https://dev.azure.com/{organization}/{project}/_apis/build/builds/{buildId}/artifacts?artifactName=map-tiles&api-version=7.0
```

### Optional: Azure Blob Storage Deployment

Für einfacheren Download können Sie die MBTiles-Datei in Azure Blob Storage veröffentlichen:

1. Kommentieren Sie die `DeployToStorage`-Stage in `azure-pipelines.yml` ein
2. Ersetzen Sie `<Your-Azure-Service-Connection>` und `<storage-account-name>`
3. Erstellen Sie einen Azure Blob Storage Container: `map-tiles`
4. Die URL lautet dann: `https://<storage-account>.blob.core.windows.net/map-tiles/hessen.mbtiles`

## 🧪 Lokale Tile-Generierung (Development)

Für lokale Tests können Sie Tiles manuell herunterladen:

### Voraussetzungen

```bash
pip install -r requirements.txt
```

### Script ausführen

```bash
cd scripts
python download_tiles.py
```

Das Script:
- Lädt Tiles für Hessen herunter (Zoom 10-14)
- Erstellt `hessen.mbtiles` (~250 MB)
- Validiert die Datei mit SQLite

Für kleinere Testregionen passen Sie die `CONFIG`-Werte in `scripts/download_tiles.py` an (z. B. `bbox`, `zoom_min`, `zoom_max`, `output_file`).

## 📦 Dependencies

### Flutter Packages

| Package | Version | Zweck |
|---------|---------|-------|
| `flutter_map` | ^7.0.2 | Haupt-Kartenbibliothek |
| `flutter_map_mbtiles` | ^1.0.4 | MBTiles-Provider für flutter_map |
| `latlong2` | ^0.9.1 | Geografische Koordinaten |
| `path_provider` | ^2.1.4 | Zugriff auf App-Verzeichnisse |
| `dio` | ^5.7.0 | Downloads mit Progress-Tracking |
| `http` | ^1.2.2 | HTTP-Client |

### Python Dependencies (CI/CD)

- `requests` - HTTP-Downloads der Tile-Dateien
- `tqdm` - Fortschrittsanzeige im Terminal

Installationsbefehl:

```bash
pip install -r requirements.txt
```

## 🗺️ Kartendaten

### Quelle

- **Tiles**: OpenStreetMap (https://tile.openstreetmap.org)
- **Lizenz**: Open Database License (ODbL)
- **Attribution**: © OpenStreetMap contributors

### Region: Hessen

- **Norden**: 51.6569° N
- **Süden**: 49.3963° N
- **Osten**: 10.2358° E
- **Westen**: 7.7726° E
- **Zoom**: 10-14
- **Dateigröße**: ~150-300 MB

### Rechtliche Hinweise

Bei Verwendung von OpenStreetMap-Daten muss eine Attribution erfolgen:

```
© OpenStreetMap contributors
```

Weitere Informationen: https://www.openstreetmap.org/copyright

## 🐛 Troubleshooting

### "Keine Kartendaten verfügbar"

- Kartendaten müssen zuerst heruntergeladen werden
- Download-URL in `map_config.dart` prüfen
- Netzwerkverbindung und Firewall überprüfen

### "Fehler beim Laden der Kartendaten"

- MBTiles-Datei könnte beschädigt sein
- Über Optionen-Menü löschen und neu herunterladen
- Speicherplatz prüfen (~250 MB erforderlich)

### Pipeline fehlgeschlagen

- Python-Dependencies prüfen: `pip install -r requirements.txt`
- Rate-Limiting von OpenStreetMap-Server (zu viele Anfragen)
- Timeout erhöhen in `azure-pipelines.yml` (aktuell: 120 Minuten)

### Windows Developer Mode

Falls Sie den Fehler "symlink support" sehen:

1. Öffnen Sie Windows-Einstellungen
2. Gehen Sie zu "Für Entwickler"
3. Aktivieren Sie den "Entwicklermodus"
4. Alternativ: `flutter config --enable-windows-desktop`

## 🔮 Erweiterungen

### Mehrere Regionen unterstützen

1. Erweitern Sie `MapConfig` um eine Region-Enumeration
2. Passen Sie `MapDownloader` an, um mehrere MBTiles-Dateien zu verwalten
3. Fügen Sie ein Regions-Auswahlmenü hinzu
4. Erstellen Sie mehrere Pipeline-Jobs für verschiedene Regionen

### Automatische Updates

1. Speichern Sie Versions-Metadaten im Blob Storage
2. Implementieren Sie einen Update-Check beim App-Start
3. Zeigen Sie eine Benachrichtigung bei verfügbaren Updates an

### Marker und Overlays

```dart
TileLayer(
  tileProvider: _tileProvider,
  urlTemplate: 'mbtiles://hessen',
),
MarkerLayer(
  markers: [
    Marker(
      point: LatLng(50.1109, 8.6821), // Frankfurt
      child: Icon(Icons.location_pin),
    ),
  ],
),
```

## 📄 Lizenz

Dieses Projekt ist unter der MIT Lizenz veröffentlicht.

**Kartendaten-Lizenz**: Die OpenStreetMap-Daten unterliegen der Open Database License (ODbL).

## 🤝 Beitragen

Contributions sind willkommen! Bitte erstellen Sie einen Pull Request oder öffnen Sie ein Issue.

## 📧 Support

Bei Fragen oder Problemen erstellen Sie bitte ein Issue im Repository.

---

Erstellt mit ❤️ unter Verwendung von Flutter und OpenStreetMap
