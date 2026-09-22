import 'package:flutter/foundation.dart';

/// Kategorisiert Fehler im Offline-Kartenbetrieb für bessere Fehlerbehandlung und Logging.
enum MapErrorCategory {
  /// Asset (Style JSON, Sprites, Glyphs) nicht gefunden
  assetMissing,
  
  /// JSON kann nicht geparst werden
  jsonInvalid,
  
  /// MBTiles-Datei nicht vorhanden
  mbtilesMissing,
  
  /// MBTiles-Format wird nicht unterstützt
  mbtilesFormatUnsupported,
  
  /// SQLite-Fehler beim Lesen der MBTiles
  sqliteError,
  
  /// Vektor-Style hat keine Quellen
  styleMissingSource,
  
  /// Vektor-Layer mit Style nicht kompatibel
  styleLayerIncompatible,
  
  /// Theme Reader kann Stil nicht parsen
  themeParseError,
  
  /// Andere/unklassifizierte Fehler
  unknown,
}

/// Strukturierter Fehler mit Kategorie, nutzerfreundlicher und technischer Meldung.
class MapError {
  final MapErrorCategory category;
  final String userMessage;
  final String technicalMessage;
  final Object? originalError;
  final StackTrace? stackTrace;

  MapError({
    required this.category,
    required this.userMessage,
    required this.technicalMessage,
    this.originalError,
    this.stackTrace,
  });

  @override
  String toString() => userMessage;
}

/// Service zur Klassifizierung und Logging von Map-Fehlern.
class MapErrorHandler {
  static const String _logTag = '[MapError]';

  /// Klassifiziert einen Fehler und gibt strukturierte Fehlerinformation zurück.
  static MapError classify(
    Object error,
    StackTrace? stackTrace, {
    String? context,
  }) {
    final errorStr = error.toString().toLowerCase();
    final contextStr = context != null ? ' ($context)' : '';

    // Asset Fehler
    if (errorStr.contains('asset') && errorStr.contains('not found')) {
      final msg = 'Asset nicht gefunden$contextStr. Überprüfen Sie die Datei im assets/maps Verzeichnis.';
      _logError(msg, error, stackTrace);
      return MapError(
        category: MapErrorCategory.assetMissing,
        userMessage: msg,
        technicalMessage: error.toString(),
        originalError: error,
        stackTrace: stackTrace,
      );
    }

    // JSON Parse Fehler
    if (errorStr.contains('json') || errorStr.contains('decode')) {
      final msg = 'Style-JSON ist ungültig$contextStr. JSON-Syntax prüfen.';
      _logError(msg, error, stackTrace);
      return MapError(
        category: MapErrorCategory.jsonInvalid,
        userMessage: msg,
        technicalMessage: error.toString(),
        originalError: error,
        stackTrace: stackTrace,
      );
    }

    // MBTiles nicht vorhanden
    if (errorStr.contains('file') && errorStr.contains('not') && errorStr.contains('exist')) {
      final msg = 'MBTiles-Datei existiert nicht$contextStr.';
      _logError(msg, error, stackTrace);
      return MapError(
        category: MapErrorCategory.mbtilesMissing,
        userMessage: msg,
        technicalMessage: error.toString(),
        originalError: error,
        stackTrace: stackTrace,
      );
    }

    // SQLite Fehler
    if (errorStr.contains('sqlite') || errorStr.contains('database')) {
      final msg = 'Fehler beim Lesen der Kartendatenbank$contextStr. Datei beschädigt?';
      _logError(msg, error, stackTrace);
      return MapError(
        category: MapErrorCategory.sqliteError,
        userMessage: msg,
        technicalMessage: error.toString(),
        originalError: error,
        stackTrace: stackTrace,
      );
    }

    // Style-spezifische Fehler
    if (errorStr.contains('source') && errorStr.contains('tile')) {
      final msg = 'Style hat keine oder ungültige Tile-Quellen$contextStr.';
      _logError(msg, error, stackTrace);
      return MapError(
        category: MapErrorCategory.styleMissingSource,
        userMessage: msg,
        technicalMessage: error.toString(),
        originalError: error,
        stackTrace: stackTrace,
      );
    }

    if (errorStr.contains('layer') && errorStr.contains('incompatible')) {
      final msg = 'Style-Layer nicht mit Kartendaten kompatibel$contextStr.';
      _logError(msg, error, stackTrace);
      return MapError(
        category: MapErrorCategory.styleLayerIncompatible,
        userMessage: msg,
        technicalMessage: error.toString(),
        originalError: error,
        stackTrace: stackTrace,
      );
    }

    if (errorStr.contains('theme')) {
      final msg = 'Kartenstil kann nicht verarbeitet werden$contextStr.';
      _logError(msg, error, stackTrace);
      return MapError(
        category: MapErrorCategory.themeParseError,
        userMessage: msg,
        technicalMessage: error.toString(),
        originalError: error,
        stackTrace: stackTrace,
      );
    }

    // Default: unbekannter Fehler
    final msg = 'Kartenfehler$contextStr. Versuchen Sie, die App neu zu starten.';
    _logError(msg, error, stackTrace);
    return MapError(
      category: MapErrorCategory.unknown,
      userMessage: msg,
      technicalMessage: error.toString(),
      originalError: error,
      stackTrace: stackTrace,
    );
  }

  /// Klassifiziert Format-Fehler spezifisch für MBTiles-Format.
  static MapError classifyUnsupportedFormat(
    String format, {
    String? mbtilesPath,
  }) {
    final msg = 'Kartendatenformat "$format" wird nicht unterstützt. '
        'Erwartet: png, jpg, jpeg, webp (Raster) oder pbf (Vektor).';
    _logError(msg, null, null, 'File: $mbtilesPath');
    return MapError(
      category: MapErrorCategory.mbtilesFormatUnsupported,
      userMessage: msg,
      technicalMessage: 'Unsupported format: $format at $mbtilesPath',
    );
  }

  /// Strukturiertes Debug-Logging mit Kontext.
  static void logDebug(String message, {String? context}) {
    if (kDebugMode) {
      final contextStr = context != null ? ' [$context]' : '';
      debugPrint('$_logTag$contextStr $message');
    }
  }

  /// Strukturiertes Error-Logging mit Kontext.
  static void logError(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? context,
  }) {
    _logError(message, error, stackTrace, context);
  }

  /// Fehler werden bewusst auch im Release geloggt: auf dem Pi laeuft nur
  /// Release, und ohne diese Zeilen ist eine leere Karte dort nicht
  /// diagnostizierbar.
  static void _logError(
    String message,
    Object? error,
    StackTrace? stackTrace, [
    String? context,
  ]) {
    final contextStr = context != null ? ' [$context]' : '';
    debugPrint('$_logTag ERROR$contextStr: $message');
    if (error != null) {
      debugPrint('$_logTag  Exception: $error');
    }
    if (stackTrace != null) {
      debugPrint('$_logTag  Stacktrace: $stackTrace');
    }
  }
}

/// Exception für MBTiles-spezifische Fehler.
class MbTilesException implements Exception {
  final String message;
  final MapErrorCategory category;
  final Object? originalError;

  MbTilesException(
    this.message, {
    this.category = MapErrorCategory.unknown,
    this.originalError,
  });

  @override
  String toString() => message;
}
