import 'package:flutter_map/flutter_map.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:latlong2/latlong.dart';

/// Konfiguration fuer die Offline-Karte.
///
/// [MapConfig] ist eine unveraenderliche Instanz und wird an [MapView],
/// [MapDownloader] und die Dialoge uebergeben. Die Standardwerte entsprechen
/// dem urspruenglichen Hessen-Setup, damit bestehende Projekte ohne
/// Anpassung weiterlaufen.

/// Speicherort-Optionen fuer Offline-Karten
enum MapStorageLocation {
  /// Application Support Directory - fuer interne App-Daten
  /// Windows: C:\Users\[user]\AppData\Roaming\[app]
  /// Android: /data/data/[package]/files
  /// iOS/macOS: ~/Library/Application Support/[app]
  applicationSupport,

  /// Documents Directory - fuer benutzergenerierte Daten
  /// Windows: C:\Users\[user]\Documents\[app]
  /// Android: /storage/emulated/0/Documents (Android 10+)
  /// iOS/macOS: ~/Documents
  applicationDocuments,

  /// Downloads Directory - fuer heruntergeladene Dateien
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
  /// Kartenmittelpunkt beim Start.
  final LatLng center;

  /// Optionale Begrenzung der Kamera. `null` bedeutet: keine Begrenzung.
  final LatLngBounds? cameraBounds;

  final double minZoom;
  final double maxZoom;
  final double initialZoom;

  /// Dateiname der MBTiles-Datei im Speicherverzeichnis.
  final String mbtilesFilename;

  /// Download-Quelle fuer [MapDownloader.downloadMap].
  final String downloadUrl;

  /// Geschaetzte Dateigroesse fuer die Benutzer-Info (in MB).
  final int estimatedFileSizeMB;

  /// Wo Offline-Karten abgelegt werden.
  final MapStorageLocation storageLocation;

  /// Unterverzeichnis innerhalb des gewaehlten Speicherorts.
  final String storageSubdirectory;

  /// Absoluter Pfad, nur relevant wenn
  /// [storageLocation] == [MapStorageLocation.custom].
  final String? customStoragePath;

  /// Vektor-Styles, die der Reihe nach probiert werden. Asset-Pfade muessen
  /// vollstaendig qualifiziert sein, also inklusive
  /// `packages/<package_name>/` wenn sie aus einem Package kommen.
  final List<String> vectorStyleAssets;

  /// Index in [vectorStyleAssets], der zuerst geladen wird.
  final int initialVectorStyleIndex;

  /// Endpunkt des lokalen Valhalla-Servers.
  final Uri valhallaBaseUri;

  /// Kandidatenpfade fuer die NMEA-Tourdatei des GPS-Simulators.
  /// Relative Pfade werden gegen das aktuelle Arbeitsverzeichnis aufgeloest.
  final List<String> gpsTourFilePaths;

  /// urlTemplate des Raster-[TileLayer]. Wird von MBTiles nicht wirklich
  /// aufgerufen, muss aber gesetzt sein.
  final String rasterUrlTemplate;

  // ===== VEKTOR-SPEICHERBUDGET =====
  // Zielplattform ist ein Raspberry Pi mit 4 GB RAM, auf dem zusaetzlich die
  // Valhalla-Routing-Engine laeuft. Die Defaults hier entsprechen denen von
  // VectorTileLayer; kleinere Werte senken den Working Set.

  /// Groesse des Caches fuer rohe Kacheldaten in Bytes.
  /// `null` = Default von `VectorTileLayer` (10 MB).
  final int? memoryTileCacheMaxSize;

  /// Anzahl geparster Vektorkacheln im Speicher.
  /// `null` = Default von `VectorTileLayer` (20). Muss < 100 sein.
  final int? memoryTileDataCacheMaxSize;

  /// Groesse des Text-/Label-Caches.
  /// `null` = Default von `VectorTileLayer` (100).
  final int? textCacheMaxSize;

  /// Anzahl der Worker-Isolates fuer das Parsen und Rendern.
  /// `null` = Default von `VectorTileLayer`. Wirkt nur im Release-Build:
  /// im Debug-Modus benutzt executor_lib grundsaetzlich keine Isolates.
  final int? vectorConcurrency;

  /// Renderpfad der Vektorkacheln.
  ///
  /// [VectorTileLayerMode.raster] (Default der Lib) rastert jede Kachel per
  /// `toImageSync()` auf der GPU zwischen. Auf Geraeten mit schwachem oder
  /// defektem GPU-Stack bleibt die Karte dann leer - in dem Fall
  /// [VectorTileLayerMode.vector] verwenden, das direkt auf die Canvas malt.
  /// `null` = Default von `VectorTileLayer`.
  final VectorTileLayerMode? vectorLayerMode;

  /// Zahl der Kachelreihen, die ausserhalb des sichtbaren Bereichs
  /// mitgeladen werden (nur Raster-Modus).
  ///
  /// Default 0, gemessen auf dem Pi 4 bei 1920x1080: der Pufferring von
  /// flutter_map (dort Default 1) verdoppelt fast die Kachelzahl, und weil
  /// executor_lib Auftraege in umgekehrter Reihenfolge abarbeitet, kommt er
  /// sogar vor der Bildmitte dran. Mit 0 ist die Karte etwa doppelt so
  /// schnell vollstaendig. Preis: beim Verschieben erscheinen die
  /// Randkacheln erst, wenn sie ins Bild kommen - fuer fluessigeres Ziehen
  /// auf schneller Hardware 1 setzen.
  final int panBuffer;

  /// Aufloesungsfaktor beim Rastern der Kacheln (nur Raster-Modus).
  ///
  /// `null` = Pixelverhaeltnis des Bildschirms. vector_map_tiles rastert
  /// sonst fest mit 2.0; auf dem Pi (Pixelverhaeltnis 1) ist das die
  /// vierfache Pixelmenge und der vierfache Speicher je Kachelbild, bei z8
  /// ~200 statt ~45 ms Raster-Zeit pro Frame.
  final double? rasterTileScale;

  /// Standard-Vektorstyles, die dieses Package mitliefert.
  static const List<String> packageVectorStyleAssets = [
    'packages/local_map/assets/maps/style.json',
    'packages/local_map/assets/maps/style_second.json',
    'packages/local_map/assets/maps/style_navigation.json',
  ];

  static const List<String> _defaultGpsTourFilePaths = [
    'scripts/gpstest/GPS-Adnan-Tour.txt',
    'scripts/GpsTest/GPS-Adnan-Tour.txt',
  ];

  MapConfig({
    this.center = const LatLng(50.6521, 9.1624),
    this.cameraBounds,
    this.minZoom = 10,
    this.maxZoom = 14,
    this.initialZoom = 11,
    this.mbtilesFilename = 'germany.mbtiles',
    this.downloadUrl = 'https://example.com/artifacts/hessen.mbtiles',
    this.estimatedFileSizeMB = 250,
    this.storageLocation = MapStorageLocation.applicationSupport,
    this.storageSubdirectory = 'offline_maps',
    this.customStoragePath,
    this.vectorStyleAssets = packageVectorStyleAssets,
    this.initialVectorStyleIndex = 2,
    Uri? valhallaBaseUri,
    this.gpsTourFilePaths = _defaultGpsTourFilePaths,
    this.rasterUrlTemplate = 'mbtiles://local',
    this.memoryTileCacheMaxSize,
    this.memoryTileDataCacheMaxSize,
    this.textCacheMaxSize,
    this.vectorConcurrency,
    this.vectorLayerMode,
    this.panBuffer = 0,
    this.rasterTileScale,
  }) : assert(panBuffer >= 0),
       assert(rasterTileScale == null || rasterTileScale > 0),
       valhallaBaseUri = valhallaBaseUri ?? Uri.parse('http://127.0.0.1:8002');

  /// Bounding Box von Hessen.
  static LatLngBounds get hessenBounds => LatLngBounds(
    const LatLng(49.3963, 7.7726), // Sued-West
    const LatLng(51.6569, 10.2358), // Nord-Ost
  );

  /// Das urspruengliche Setup dieses Projekts: Hessen inkl. Kamera-Begrenzung.
  static MapConfig get hessen => MapConfig(cameraBounds: hessenBounds);

  /// Wird verwendet, wenn einem Widget oder Service keine Config uebergeben
  /// wird. Einmalig beim App-Start setzen, z.B. in `main()`.
  static MapConfig defaults = hessen;

  MapConfig copyWith({
    LatLng? center,
    LatLngBounds? cameraBounds,
    bool clearCameraBounds = false,
    double? minZoom,
    double? maxZoom,
    double? initialZoom,
    String? mbtilesFilename,
    String? downloadUrl,
    int? estimatedFileSizeMB,
    MapStorageLocation? storageLocation,
    String? storageSubdirectory,
    String? customStoragePath,
    List<String>? vectorStyleAssets,
    int? initialVectorStyleIndex,
    Uri? valhallaBaseUri,
    List<String>? gpsTourFilePaths,
    String? rasterUrlTemplate,
    int? memoryTileCacheMaxSize,
    int? memoryTileDataCacheMaxSize,
    int? textCacheMaxSize,
    int? vectorConcurrency,
    VectorTileLayerMode? vectorLayerMode,
    int? panBuffer,
    double? rasterTileScale,
  }) {
    return MapConfig(
      center: center ?? this.center,
      cameraBounds: clearCameraBounds
          ? null
          : (cameraBounds ?? this.cameraBounds),
      minZoom: minZoom ?? this.minZoom,
      maxZoom: maxZoom ?? this.maxZoom,
      initialZoom: initialZoom ?? this.initialZoom,
      mbtilesFilename: mbtilesFilename ?? this.mbtilesFilename,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      estimatedFileSizeMB: estimatedFileSizeMB ?? this.estimatedFileSizeMB,
      storageLocation: storageLocation ?? this.storageLocation,
      storageSubdirectory: storageSubdirectory ?? this.storageSubdirectory,
      customStoragePath: customStoragePath ?? this.customStoragePath,
      vectorStyleAssets: vectorStyleAssets ?? this.vectorStyleAssets,
      initialVectorStyleIndex:
          initialVectorStyleIndex ?? this.initialVectorStyleIndex,
      valhallaBaseUri: valhallaBaseUri ?? this.valhallaBaseUri,
      gpsTourFilePaths: gpsTourFilePaths ?? this.gpsTourFilePaths,
      rasterUrlTemplate: rasterUrlTemplate ?? this.rasterUrlTemplate,
      memoryTileCacheMaxSize:
          memoryTileCacheMaxSize ?? this.memoryTileCacheMaxSize,
      memoryTileDataCacheMaxSize:
          memoryTileDataCacheMaxSize ?? this.memoryTileDataCacheMaxSize,
      textCacheMaxSize: textCacheMaxSize ?? this.textCacheMaxSize,
      vectorConcurrency: vectorConcurrency ?? this.vectorConcurrency,
      vectorLayerMode: vectorLayerMode ?? this.vectorLayerMode,
      panBuffer: panBuffer ?? this.panBuffer,
      rasterTileScale: rasterTileScale ?? this.rasterTileScale,
    );
  }
}
