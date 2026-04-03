import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../config/map_config.dart';

/// Service für das Herunterladen und Verwalten von Offline-Kartendaten
class MapDownloader {
  final Dio _dio = Dio();
  String? _downloadPath;
  final MapStorageLocation _storageLocation;
  final String? _customPath;

  /// Erstellt einen MapDownloader mit konfigurierbarem Speicherort
  /// 
  /// [storageLocation] Bestimmt, wo die Karten gespeichert werden
  /// [customPath] Erforderlich wenn storageLocation == custom
  MapDownloader({
    MapStorageLocation? storageLocation,
    String? customPath,
  })  : _storageLocation = storageLocation ?? MapConfig.defaultStorageLocation,
        _customPath = customPath ?? MapConfig.customStoragePath {
    if (_storageLocation == MapStorageLocation.custom && _customPath == null) {
      throw ArgumentError(
        'customPath muss angegeben werden wenn storageLocation == custom',
      );
    }
  }

  /// Initialisiert den Downloader und setzt den Download-Pfad
  Future<void> initialize() async {
    final baseDir = await _getBaseDirectory();
    if(MapStorageLocation.custom == _storageLocation) {
      // Bei benutzerdefiniertem Pfad verwenden wir diesen direkt
      _downloadPath = _customPath;
    } else {
      // Ansonsten erstellen wir den Standard-Unterordner
      _downloadPath = p.join(baseDir.path, MapConfig.storageSubdirectory);
    }
    
    // Erstelle das Verzeichnis, falls es nicht existiert
    final dir = Directory(_downloadPath!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  /// Ermittelt das Basis-Verzeichnis basierend auf der Konfiguration
  Future<Directory> _getBaseDirectory() async {
    switch (_storageLocation) {
      case MapStorageLocation.applicationSupport:
        return await getApplicationSupportDirectory();

      case MapStorageLocation.applicationDocuments:
        return await getApplicationDocumentsDirectory();

      case MapStorageLocation.downloads:
        final dir = await getDownloadsDirectory();
        if (dir == null) {
          throw UnsupportedError(
            'Downloads-Verzeichnis nicht verfügbar auf dieser Plattform',
          );
        }
        return dir;

      case MapStorageLocation.externalStorage:
        if (!Platform.isAndroid) {
          throw UnsupportedError(
            'External Storage nur auf Android verfügbar',
          );
        }
        final dir = await getExternalStorageDirectory();
        if (dir == null) {
          throw Exception('External Storage nicht verfügbar');
        }
        return dir;

      case MapStorageLocation.custom:
        return Directory(_customPath!);
    }
  }

  /// Gibt den vollständigen Pfad zur MBTiles-Datei zurück
  Future<String> getMBTilesPath() async {
    if (_downloadPath == null) {
      await initialize();
    }
    return p.join(_downloadPath!, MapConfig.mbtilesFilename);
  }

  /// Prüft, ob die MBTiles-Datei bereits existiert
  Future<bool> isMapDownloaded() async {
    final path = await getMBTilesPath();
    final file = File(path);
    return await file.exists();
  }

  /// Löscht die heruntergeladene MBTiles-Datei
  Future<void> deleteMap() async {
    final path = await getMBTilesPath();
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Lädt die MBTiles-Datei herunter
  /// 
  /// [onProgress] Callback wird mit dem Fortschritt aufgerufen (0.0 bis 1.0)
  /// Wirft eine [Exception] bei Fehlern
  Future<void> downloadMap({
    required Function(double progress) onProgress,
  }) async {
    try {
      final path = await getMBTilesPath();
      
      // Download mit Progress-Tracking
      await _dio.download(
        MapConfig.downloadUrl,
        path,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            final progress = received / total;
            onProgress(progress);
          }
        },
      );

      // Validiere die heruntergeladene Datei
      await _validateMBTilesFile(path);
    } catch (e) {
      // Lösche unvollständigen Download
      try {
        final path = await getMBTilesPath();
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // Ignoriere Fehler beim Löschen
      }
      
      throw Exception('Fehler beim Herunterladen der Kartendaten: $e');
    }
  }

  /// Validiert, ob die Datei eine gültige SQLite/MBTiles-Datei ist
  Future<void> _validateMBTilesFile(String path) async {
    final file = File(path);
    
    // Prüfe ob Datei existiert und nicht leer ist
    if (!await file.exists()) {
      throw Exception('Datei wurde nicht erstellt');
    }

    final fileSize = await file.length();
    if (fileSize < 1024) {
      throw Exception('Datei ist zu klein (möglicherweise korrupt)');
    }

    // Prüfe SQLite Header (erste 16 Bytes sollten "SQLite format 3" sein)
    final bytes = await file.openRead(0, 16).first;
    final header = String.fromCharCodes(bytes.take(15));
    
    if (!header.startsWith('SQLite format 3')) {
      throw Exception('Datei ist keine gültige SQLite/MBTiles-Datei');
    }
  }

  /// Gibt die Größe der heruntergeladenen Datei in Bytes zurück
  Future<int?> getDownloadedFileSize() async {
    if (!await isMapDownloaded()) {
      return null;
    }
    
    final path = await getMBTilesPath();
    final file = File(path);
    return await file.length();
  }

  /// Kopiert eine lokal vorhandene MBTiles-Datei in das App-Verzeichnis
  /// 
  /// Nützlich für Entwicklung/Testing, um die vom Python-Skript
  /// heruntergeladene Datei zu verwenden, ohne sie neu herunterladen zu müssen.
  /// 
  /// [sourcePath] Der Pfad zur Quell-MBTiles-Datei
  /// [onProgress] Optional: Callback für Kopierfortschritt (0.0 bis 1.0)
  Future<void> copyLocalMap({
    required String sourcePath,
    Function(double progress)? onProgress,
  }) async {
    try {
      final sourceFile = File(sourcePath);
      
      if (!await sourceFile.exists()) {
        throw Exception('Quelldatei nicht gefunden: $sourcePath');
      }

      final targetPath = await getMBTilesPath();
      final targetFile = File(targetPath);
      
      // Prüfe ob Ziel bereits existiert
      if (await targetFile.exists()) {
        await targetFile.delete();
      }

      // Kopiere Datei mit Progress-Tracking
      final fileSize = await sourceFile.length();
      final source = sourceFile.openRead();
      final sink = targetFile.openWrite();
      
      int bytesCopied = 0;
      
      await for (final chunk in source) {
        sink.add(chunk);
        bytesCopied += chunk.length;
        
        if (onProgress != null && fileSize > 0) {
          onProgress(bytesCopied / fileSize);
        }
      }
      
      await sink.flush();
      await sink.close();
      
      // Validiere die kopierte Datei
      await _validateMBTilesFile(targetPath);
      
      onProgress?.call(1.0);
    } catch (e) {
      throw Exception('Fehler beim Kopieren der Kartendaten: $e');
    }
  }

  /// Debug-Methode: Gibt den aktuellen Speicherpfad zurück
  Future<String> getStoragePath() async {
    if (_downloadPath == null) {
      await initialize();
    }
    return _downloadPath!;
  }

  /// Gibt Informationen über den aktuellen Speicherort zurück
  String get storageLocationName {
    switch (_storageLocation) {
      case MapStorageLocation.applicationSupport:
        return 'Application Support';
      case MapStorageLocation.applicationDocuments:
        return 'Dokumente';
      case MapStorageLocation.downloads:
        return 'Downloads';
      case MapStorageLocation.externalStorage:
        return 'External Storage';
      case MapStorageLocation.custom:
        return 'Benutzerdefiniert: $_customPath';
    }
  }
}
