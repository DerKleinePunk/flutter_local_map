import 'package:flutter/foundation.dart';

/// Kategorisiert Fehler im Offline-Kartenbetrieb für bessere Fehlerbehandlung und Logging.
enum MapErrorCategory {
  /// Der Karte wurde keine MBTiles-Datei übergeben
  noMapData,

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
///
/// [userMessage] ist englisch. Wer die Meldung übersetzt anzeigen will, wählt
/// den Text anhand von [category], z. B. im `errorBuilder` von `MapView`.
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

/// Schwere einer Meldung an [MapErrorHandler.sink].
enum MapLogLevel { debug, info, error }

/// Nimmt die Meldungen der Karte entgegen, siehe [MapErrorHandler.sink].
typedef MapLogSink =
    void Function(
      MapLogLevel level,
      String message, {
      String? context,
      Object? error,
      StackTrace? stackTrace,
    });

/// Service zur Klassifizierung und Logging von Map-Fehlern.
class MapErrorHandler {
  static const String _logTag = '[MapError]';

  /// Leitet alle Meldungen der Karte an das Logging des Gastgebers um.
  ///
  /// Ohne Angabe gehen sie per `debugPrint` mit dem Präfix `[MapError]` auf
  /// die Konsole. Debug-Meldungen kommen in beiden Fällen nur im Debug-Build.
  static MapLogSink? sink;

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
      final msg =
          'Map asset not found$contextStr. Check the files in assets/maps.';
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
      final msg = 'Map style JSON is invalid$contextStr.';
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
    if (errorStr.contains('file') &&
        errorStr.contains('not') &&
        errorStr.contains('exist')) {
      final msg = 'Map file does not exist$contextStr.';
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
      final msg = 'Could not read the map file$contextStr. Is it damaged?';
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
      final msg = 'Map style has no valid tile source$contextStr.';
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
      final msg = 'Map style does not match the map data$contextStr.';
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
      final msg = 'Map style cannot be processed$contextStr.';
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
    final msg = 'Map error$contextStr. Try restarting the app.';
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
    final msg =
        'Map data format "$format" is not supported. '
        'Expected png, jpg, jpeg, webp (raster) or pbf (vector).';
    _logError(msg, null, null, 'File: $mbtilesPath');
    return MapError(
      category: MapErrorCategory.mbtilesFormatUnsupported,
      userMessage: msg,
      technicalMessage: 'Unsupported format: $format at $mbtilesPath',
    );
  }

  /// Strukturiertes Debug-Logging mit Kontext.
  static void logDebug(String message, {String? context}) {
    if (!kDebugMode) {
      return;
    }
    final target = sink;
    if (target != null) {
      target(MapLogLevel.debug, message, context: context);
      return;
    }
    final contextStr = context != null ? ' [$context]' : '';
    debugPrint('$_logTag$contextStr $message');
  }

  /// Meldungen ueber den Zustand der Karte, die auch im Release sichtbar sind.
  ///
  /// Gedacht fuer die wenigen Entscheidungen, die man auf dem Zielgeraet
  /// nachvollziehen koennen muss - etwa welcher Style tatsaechlich geladen
  /// wurde. Alles Weitere gehoert in [logDebug].
  static void logInfo(String message, {String? context}) {
    final target = sink;
    if (target != null) {
      target(MapLogLevel.info, message, context: context);
      return;
    }
    final contextStr = context != null ? ' [$context]' : '';
    debugPrint('$_logTag INFO$contextStr: $message');
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
    final target = sink;
    if (target != null) {
      target(
        MapLogLevel.error,
        message,
        context: context,
        error: error,
        stackTrace: stackTrace,
      );
      return;
    }
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
