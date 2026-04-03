import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Konfiguration für die Karten-Anwendung
///
/// Enthält Bounding Box, Zoom-Levels und Download-URLs für Hessen

/// Speicherort-Optionen für Offline-Karten
enum MapStorageLocation {
  /// Application Support Directory - für interne App-Daten
  /// Windows: C:\Users\[user]\AppData\Roaming\[app]
  /// Android: /data/data/[package]/files
  /// iOS/macOS: ~/Library/Application Support/[app]
  applicationSupport,

  /// Documents Directory - für benutzergenerierte Daten
  /// Windows: C:\Users\[user]\Documents\[app]
  /// Android: /storage/emulated/0/Documents (Android 10+)
  /// iOS/macOS: ~/Documents
  applicationDocuments,

  /// Downloads Directory - für heruntergeladene Dateien
  /// Windows: C:\Users\<user>\Downloads
  /// Android: /storage/emulated/0/Download
  downloads,

  /// External Storage Directory - nur Android
  /// Android: /storage/emulated/0/Android/data/[package]/files
  externalStorage,

  /// Benutzerdefinierter Pfad
  custom,
}

class MapConfig {
  // Hessen Bounding Box
  static const double northLat = 51.6569;
  static const double southLat = 49.3963;
  static const double eastLng = 10.2358;
  static const double westLng = 7.7726;

  // Zentrum von Hessen (ungefähr Kassel)
  static const double centerLat = 50.6521;
  static const double centerLng = 9.1624;

  // Zoom-Level Einstellungen
  static const int minZoom = 10;
  static const int maxZoom = 14;
  static const int initialZoom = 11;

  // MBTiles Dateiname
  static const String mbtilesFilename = 'hessen.mbtiles';

  // Download-URL (wird nach Azure Pipeline-Setup aktualisiert)
  // TODO: Ersetze diese URL mit der tatsächlichen Azure Artifacts/Blob Storage URL
  static const String downloadUrl =
      'https://example.com/artifacts/hessen.mbtiles';

  // Geschätzte Dateigröße für Benutzer-Info (in MB)
  static const int estimatedFileSizeMB = 250;

  // ===== STORAGE KONFIGURATION =====

  /// Standard-Speicherort für Offline-Karten
  static const MapStorageLocation defaultStorageLocation =
      MapStorageLocation.applicationSupport;

  /// Unterverzeichnis innerhalb des gewählten Speicherorts
  static const String storageSubdirectory = 'offline_maps';

  /// Benutzerdefinierter Pfad (nur wenn storageLocation == custom)
  static String? customStoragePath;

  // LatLngBounds für Hessen
  static LatLngBounds get hessenBounds => LatLngBounds(
    const LatLng(southLat, westLng), // Süd-West
    const LatLng(northLat, eastLng), // Nord-Ost
  );

  // Zentrum als LatLng
  static LatLng get center => const LatLng(centerLat, centerLng);
}
