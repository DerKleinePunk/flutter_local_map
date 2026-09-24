import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show Distance, LengthUnit;
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:mbtiles/mbtiles.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_mbtiles/vector_map_tiles_mbtiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;
import '../api/position.dart';
import '../config/map_config.dart';
import '../controller/local_map_controller.dart';
import '../services/map_camera_bounds.dart';
import '../services/map_error_handler.dart';
import '../navigation/heading_filter.dart';
import '../services/offline_geocoder.dart';

/// Farben und Maße der Ebenen, die [MapView] über die Kacheln legt.
///
/// Ohne Angabe kommen die Farben aus dem [ColorScheme] des Themes.
@immutable
class MapLayerStyle {
  final Color? routeColor;
  final double routeWidth;
  final Color? positionColor;
  final Color? onPositionColor;
  final Color? startColor;
  final Color? destinationColor;
  final Color? highlightColor;

  /// Fläche unter den Kacheln, sichtbar bis sie geladen sind. Ohne Angabe
  /// malt flutter_map sein helles Grau - bei einem dunklen Stil blitzt die
  /// Karte dann beim Öffnen hell auf. Passend zum `background`-Layer des
  /// Stils wählen.
  final Color? backgroundColor;

  const MapLayerStyle({
    this.routeColor,
    this.routeWidth = 5,
    this.positionColor,
    this.onPositionColor,
    this.startColor,
    this.destinationColor,
    this.highlightColor,
    this.backgroundColor,
  });
}

/// Die Karte: Kacheln aus einer MBTiles-Datei und darüber, was der
/// [LocalMapController] vorgibt - Route, Start und Ziel, ein hervorgehobener
/// Ort und die eigene Position.
///
/// Bedienelemente bringt die Karte nicht mit. Suchfelder, Zoomknöpfe und
/// Anzeigen legt der Gastgeber selbst darüber und steuert die Karte über den
/// Controller.
class MapView extends StatefulWidget {
  /// Pfad zur MBTiles-Datei (Raster oder Vektor/pbf).
  final String? mbtilesPath;

  /// Zoom-Grenzen, Kartenmittelpunkt, Vektorstyles usw.
  /// Ohne Angabe wird [MapConfig.defaults] verwendet.
  final MapConfig? config;

  /// Zustand und Befehle. Ohne Angabe legt die Karte einen eigenen an und
  /// zeigt dann nur die Kacheln.
  final LocalMapController? controller;

  final MapLayerStyle layerStyle;

  /// Wo das Fahrzeug im Navigationsmodus (Fahrtrichtung oben) steht, als
  /// Anteil der Kartenhöhe von oben. 0,72 lässt gut zwei Drittel der Karte
  /// für die Strecke voraus.
  final double navigationAnchor;

  /// Überblendzeit der Kamera zwischen zwei Positionsmeldungen. Etwas
  /// kürzer als der Meldetakt (1 Hz), damit die Bewegung vor der nächsten
  /// Meldung ankommt. [Duration.zero] springt ohne Überblendung.
  final Duration followAnimation;

  /// Zeigt einen Fehler an Stelle der Karte, etwa fehlende oder unlesbare
  /// Kartendaten. Ohne Angabe erscheint [MapError.userMessage] (englisch).
  /// Übersetzt wird anhand von [MapError.category].
  final Widget Function(BuildContext context, MapError error)? errorBuilder;

  const MapView({
    super.key,
    this.mbtilesPath,
    this.config,
    this.controller,
    this.layerStyle = const MapLayerStyle(),
    this.navigationAnchor = 0.72,
    this.followAnimation = const Duration(milliseconds: 900),
    this.errorBuilder,
  }) : assert(navigationAnchor >= 0.5 && navigationAnchor < 1);

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView>
    with SingleTickerProviderStateMixin
    implements LocalMapViewHandle {
  static const Set<String> _knownVectorSourceAliases = {
    'openmaptiles',
    'versatiles-shortbread',
    'shortbread',
  };

  /// Eigener Controller, nur angelegt wenn keiner uebergeben wurde.
  LocalMapController? _ownedController;
  LocalMapController get _controller =>
      widget.controller ?? (_ownedController ??= LocalMapController());
  MapController get _mapController => _controller.mapController;

  /// Erst nach dem ersten Frame von FlutterMap darf die Kamera bewegt
  /// werden; vorher wirft der MapController.
  bool _mapReady = false;

  /// Aktive Konfiguration, in [initState] aus dem Widget uebernommen.
  late MapConfig _config;

  /// Token to track initialization requests and prevent race conditions.
  /// Incremented each time _initializeTileProvider is called.
  int _initializationToken = 0;

  MbTilesTileProvider? _rasterTileProvider;
  MbTiles? _vectorMbTiles;

  /// Metadaten der offenen MBTiles. Nur fuer den Stilwechsel gehalten, der
  /// den Style ohne Neuaufbau der Kachelquelle pruefen muss.
  _MbtilesMetadataInfo? _vectorMetadata;
  TileProviders? _vectorTileProviders;
  vtr.Theme? _vectorTheme;
  SpriteStyle? _vectorSprites;
  late double _activeMinZoom;
  late double _activeMaxZoom;
  late LatLng _initialCenter;
  LatLngBounds? _activeCameraBounds;
  late double _currentZoom;
  late int _selectedVectorStyleAssetIndex;
  String? _activeVectorStyleAssetPath;
  bool _isLoading = true;
  MapError? _error;

  /// Überblendung zwischen zwei Positionsmeldungen. [_shown] ist, was der
  /// Pfeil gerade zeigt; die Kamera folgt ihm, solange der Folgemodus an ist.
  late final AnimationController _follow;
  _Pose? _followFrom;
  _Pose? _followTo;
  final ValueNotifier<_Pose?> _shown = ValueNotifier<_Pose?>(null);

  static const Set<String> _rasterFormats = {'png', 'jpg', 'jpeg', 'webp'};

  /// Weiter als das wird nicht ueberblendet, sondern gesprungen. 250 m
  /// zwischen zwei Meldungen im Sekundentakt waeren 900 km/h.
  static const double _maxBlendMeters = 250;

  List<String> get _localVectorStyleAssets => _config.vectorStyleAssets;

  bool get _isVectorMode =>
      _vectorTileProviders != null && _vectorTheme != null;

  @override
  void initState() {
    super.initState();
    _config = widget.config ?? MapConfig.defaults;
    _activeMinZoom = _config.minZoom;
    _activeMaxZoom = _config.maxZoom;
    _currentZoom = _config.initialZoom;
    _initialCenter = _config.center ?? fallbackCenter;
    _activeCameraBounds = _config.cameraBounds;
    _selectedVectorStyleAssetIndex = _localVectorStyleAssets.isEmpty
        ? 0
        : _config.initialVectorStyleIndex % _localVectorStyleAssets.length;
    _follow = AnimationController(vsync: this, duration: widget.followAnimation)
      ..addListener(_onFollowTick);
    _controller.attachView(this);
    _initializeTileProvider();
  }

  /// Gibt den Zustand der Kacheln an den Controller weiter, fuer die
  /// Anzeigen des Gastgebers.
  void _publishMapState() {
    if (!mounted || _isLoading) return;
    _controller.reportMapState(
      isVectorMode: _isVectorMode,
      activeStyleName: _isVectorMode ? _activeVectorStyleLabel() : null,
      minZoom: _activeMinZoom,
      maxZoom: _activeMaxZoom,
    );
    if (!_mapReady) {
      _controller.reportZoom(_currentZoom);
    }
  }

  Future<void> _initializeTileProvider() async {
    _disposeTileResources();

    // Increment token to invalidate any previous initialization requests
    _initializationToken++;
    final currentToken = _initializationToken;

    MapErrorHandler.logDebug(
      'Starting tile provider initialization',
      context: 'Token $_initializationToken',
    );

    if (widget.mbtilesPath == null) {
      // Check token before setState to prevent race conditions
      if (!mounted || _initializationToken != currentToken) return;

      setState(() {
        _isLoading = false;
        _error = MapError(
          category: MapErrorCategory.noMapData,
          userMessage: 'No map data available',
          technicalMessage: 'MapView.mbtilesPath is null',
        );
      });
      return;
    }

    try {
      debugPrint(
        '[map] Attempting to load MBTiles database: ${widget.mbtilesPath!}',
      );
      final metadata = await _readMbtilesMetadata(widget.mbtilesPath!);

      // Token check after first async operation
      if (_initializationToken != currentToken) {
        MapErrorHandler.logDebug(
          'Tile provider init cancelled (newer request running)',
          context: 'Token $currentToken',
        );
        return;
      }

      final format = metadata.format;
      final maxZoom = metadata.maxZoom ?? _config.maxZoom;
      final minZoom = effectiveMinZoom(
        fromMetadata: metadata.minZoom ?? _config.minZoom,
        max: maxZoom,
        tiles: metadata.bounds,
      );
      final boundedInitialZoom = _config.initialZoom.clamp(minZoom, maxZoom);
      final initialCenter = centerWithinTiles(
        configured: _config.center,
        bounds: metadata.bounds,
      );
      final cameraBounds = effectiveCameraBounds(
        configured: _config.cameraBounds,
        tiles: metadata.bounds,
      );

      if (format == 'pbf') {
        final mbtiles = MbTiles(path: widget.mbtilesPath!);
        final provider = MbTilesVectorTileProvider(mbtiles: mbtiles);

        vtr.Theme vectorTheme;
        SpriteStyle? vectorSprites;
        TileProviders vectorTileProviders;

        try {
          final styleResult = await _loadLocalVectorStyle(
            provider: provider,
            metadata: metadata,
          );
          vectorTheme = styleResult.theme;
          vectorSprites = styleResult.sprites;
          vectorTileProviders = styleResult.tileProviders;
          _activeVectorStyleAssetPath = styleResult.assetPath;
        } catch (assetError, stackTrace) {
          final mapError = MapErrorHandler.classify(
            assetError,
            stackTrace,
            context: 'Loading vector style',
          );
          MapErrorHandler.logError(
            'Fallback: helles Standardtheme ohne Styling '
            '(${mapError.category.name}: ${mapError.userMessage})',
            context: 'Vector style loading',
          );
          vectorTheme = vtr.ProvidedThemes.lightTheme();
          vectorSprites = null;
          vectorTileProviders = _buildFallbackVectorTileProviders(provider);
          _activeVectorStyleAssetPath = null;
        }

        // Token check before setState
        if (!mounted || _initializationToken != currentToken) {
          mbtiles.close();
          MapErrorHandler.logDebug(
            'Vector init cancelled (newer request running)',
            context: 'Token $currentToken',
          );
          return;
        }

        setState(() {
          _vectorMetadata = metadata;
          _vectorMbTiles = mbtiles;
          _vectorTheme = vectorTheme;
          _vectorSprites = vectorSprites;
          _vectorTileProviders = vectorTileProviders;
          _activeMinZoom = minZoom;
          _activeMaxZoom = maxZoom;
          _currentZoom = boundedInitialZoom;
          _initialCenter = initialCenter;
          _activeCameraBounds = cameraBounds;
          _isLoading = false;
          _error = null;
        });
        return;
      }

      if (format != null && !_rasterFormats.contains(format)) {
        final error = MapErrorHandler.classifyUnsupportedFormat(
          format,
          mbtilesPath: widget.mbtilesPath,
        );

        // Token check before setState
        if (!mounted || _initializationToken != currentToken) return;

        setState(() {
          _isLoading = false;
          _error = error;
        });
        MapErrorHandler.logError(
          error.technicalMessage,
          context: 'Format validation',
        );
        return;
      }

      final provider = MbTilesTileProvider.fromPath(path: widget.mbtilesPath!);

      // Token check before setState
      if (!mounted || _initializationToken != currentToken) {
        provider.dispose();
        MapErrorHandler.logDebug(
          'Raster init cancelled (newer request running)',
          context: 'Token $currentToken',
        );
        return;
      }

      setState(() {
        _rasterTileProvider = provider;
        _activeMinZoom = minZoom;
        _activeMaxZoom = maxZoom;
        _currentZoom = boundedInitialZoom;
        _initialCenter = initialCenter;
        _activeCameraBounds = cameraBounds;
        _isLoading = false;
        _error = null;
      });
    } catch (e, stackTrace) {
      // Token check even in error path
      if (_initializationToken != currentToken) {
        MapErrorHandler.logDebug(
          'Error in cancelled tile provider init',
          context: 'Token $currentToken (ignoring)',
        );
        return;
      }

      final mapError = MapErrorHandler.classify(
        e,
        stackTrace,
        context: 'TileProvider initialization',
      );

      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _error = mapError;
      });
      MapErrorHandler.logError(
        mapError.technicalMessage,
        error: e,
        stackTrace: stackTrace,
        context: 'TileProvider init failed',
      );
    }
  }

  void _disposeTileResources() {
    _rasterTileProvider?.dispose();
    _rasterTileProvider = null;

    _vectorMbTiles?.close();
    _vectorMbTiles = null;
    _vectorMetadata = null;
    _vectorTileProviders = null;
    _vectorTheme = null;
    _vectorSprites = null;

    _activeMinZoom = _config.minZoom;
    _activeMaxZoom = _config.maxZoom;
  }

  TileProviders _buildVectorTileProviders({
    required Map<String, dynamic> styleJson,
    required VectorTileProvider provider,
  }) {
    final sourceIds = <String>{
      ..._extractSourceIdsFromStyleSources(styleJson),
      ..._extractSourceIdsFromLayers(styleJson),
    };

    if (sourceIds.isEmpty) {
      throw MbTilesException(
        'Style contains no tile sources. Check style.json sources and layers.',
        category: MapErrorCategory.styleMissingSource,
      );
    }

    if (sourceIds.any(_knownVectorSourceAliases.contains)) {
      sourceIds.addAll(_knownVectorSourceAliases);
    }

    return TileProviders({
      for (final sourceId in sourceIds) sourceId: provider,
    });
  }

  TileProviders _buildFallbackVectorTileProviders(VectorTileProvider provider) {
    return TileProviders({
      for (final sourceId in _knownVectorSourceAliases) sourceId: provider,
    });
  }

  Future<_LocalVectorStyleLoadResult> _loadLocalVectorStyle({
    required VectorTileProvider provider,
    required _MbtilesMetadataInfo metadata,
  }) async {
    Object? lastError;
    final errors = <String>[];

    for (final styleAssetPath in _orderedLocalStyleAssets()) {
      try {
        MapErrorHandler.logDebug(
          'Loading local asset style',
          context: styleAssetPath,
        );

        final styleText = await rootBundle.loadString(styleAssetPath);
        final decoded = jsonDecode(styleText);

        if (decoded is! Map<String, dynamic>) {
          throw MbTilesException(
            'Style JSON is not a valid object',
            category: MapErrorCategory.jsonInvalid,
          );
        }

        _validateStyleCompatibility(
          styleJson: decoded,
          mbtilesMetadata: metadata,
        );

        final theme = vtr.ThemeReader(
          logger: const vtr.Logger.console(),
        ).read(decoded);

        final tileProviders = _buildVectorTileProviders(
          styleJson: decoded,
          provider: provider,
        );

        // Im Release sichtbar: welcher Style am Ende gilt. Die Schleife nimmt
        // den ersten, der laedt - scheitert der gewaehlte, arbeitet die App
        // still mit einem anderen weiter, und ohne diese Zeile sieht das auf
        // dem Geraet niemand.
        MapErrorHandler.logInfo(
          'Style aktiv: ${theme.layers.length} Ebenen',
          context: styleAssetPath,
        );

        return _LocalVectorStyleLoadResult(
          theme: theme,
          sprites: null,
          tileProviders: tileProviders,
          assetPath: styleAssetPath,
        );
      } catch (error, stackTrace) {
        final mapError = MapErrorHandler.classify(
          error,
          stackTrace,
          context: 'Style asset $styleAssetPath',
        );
        MapErrorHandler.logError(
          mapError.technicalMessage,
          error: error,
          stackTrace: stackTrace,
          context: 'Vector style parse',
        );
        errors.add('$styleAssetPath: ${mapError.userMessage}');
        lastError = error;
      }
    }

    // All assets failed
    final allErrors = errors.isNotEmpty
        ? errors.join('\n')
        : 'Unknown error loading styles';
    throw MbTilesException(
      'Could not load any local vector style.\n$allErrors',
      category: MapErrorCategory.assetMissing,
      originalError: lastError,
    );
  }

  List<String> _orderedLocalStyleAssets() {
    if (_localVectorStyleAssets.isEmpty) {
      return const <String>[];
    }

    final normalizedIndex =
        _selectedVectorStyleAssetIndex % _localVectorStyleAssets.length;

    return [
      ..._localVectorStyleAssets.sublist(normalizedIndex),
      ..._localVectorStyleAssets.sublist(0, normalizedIndex),
    ];
  }

  Future<void> _cycleVectorStyle() async {
    if (_localVectorStyleAssets.length < 2) {
      return;
    }

    _selectedVectorStyleAssetIndex =
        (_selectedVectorStyleAssetIndex + 1) % _localVectorStyleAssets.length;

    // Im Vektormodus wechselt nur das Thema - die Kacheldatei bleibt dieselbe.
    // Der volle Neuaufbau (Datenbank schliessen, neu oeffnen, Ladekreis statt
    // Karte, alle Kacheln neu parsen) sah auf dem Pi wie eine loechrige Karte
    // aus. Der leichte Weg tauscht Thema und Quellen im laufenden Betrieb.
    final mbtiles = _vectorMbTiles;
    final metadata = _vectorMetadata;
    if (mbtiles != null && metadata != null) {
      await _swapVectorStyle(mbtiles: mbtiles, metadata: metadata);
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    await _initializeTileProvider();
  }

  /// Tauscht nur Thema und Kachelquellen des Vektormodus aus.
  ///
  /// Schlaegt das Laden fehl, bleibt der bisherige Style stehen - eine leere
  /// Karte waere das schlechtere Ergebnis als ein nicht ausgefuehrter Wechsel.
  Future<void> _swapVectorStyle({
    required MbTiles mbtiles,
    required _MbtilesMetadataInfo metadata,
  }) async {
    final token = ++_initializationToken;
    final provider = MbTilesVectorTileProvider(mbtiles: mbtiles);

    try {
      final styleResult = await _loadLocalVectorStyle(
        provider: provider,
        metadata: metadata,
      );

      if (!mounted || _initializationToken != token) {
        return;
      }

      setState(() {
        _vectorTheme = styleResult.theme;
        _vectorSprites = styleResult.sprites;
        _vectorTileProviders = styleResult.tileProviders;
        _activeVectorStyleAssetPath = styleResult.assetPath;
      });
    } catch (error, stackTrace) {
      final mapError = MapErrorHandler.classify(
        error,
        stackTrace,
        context: 'Stilwechsel',
      );
      MapErrorHandler.logError(
        'Stilwechsel abgebrochen, bisheriger Style bleibt aktiv '
        '(${mapError.category.name})',
        error: error,
        stackTrace: stackTrace,
        context: 'Stilwechsel',
      );
    }
  }

  String _activeVectorStyleLabel() {
    final path = _activeVectorStyleAssetPath;
    if (path == null || path.isEmpty) {
      return 'Fallback';
    }

    final fileName = path.split('/').last;
    return fileName.replaceAll('.json', '');
  }

  Set<String> _extractSourceIdsFromStyleSources(
    Map<String, dynamic> styleJson,
  ) {
    final sources = styleJson['sources'];
    if (sources is! Map) {
      return const <String>{};
    }

    return sources.keys.whereType<String>().toSet();
  }

  Set<String> _extractSourceIdsFromLayers(Map<String, dynamic> styleJson) {
    final layers = styleJson['layers'];
    if (layers is! List) {
      return const <String>{};
    }

    final sourceIds = <String>{};
    for (final layer in layers) {
      if (layer is! Map) {
        continue;
      }

      final sourceId = layer['source'];
      if (sourceId is String && sourceId.isNotEmpty) {
        sourceIds.add(sourceId);
      }
    }

    return sourceIds;
  }

  Set<String> _extractSourceLayerIds(Map<String, dynamic> styleJson) {
    final layers = styleJson['layers'];
    if (layers is! List) {
      return const <String>{};
    }

    final sourceLayerIds = <String>{};
    for (final layer in layers) {
      if (layer is! Map) {
        continue;
      }

      final sourceLayerId = layer['source-layer'];
      if (sourceLayerId is String && sourceLayerId.isNotEmpty) {
        sourceLayerIds.add(sourceLayerId);
      }
    }

    return sourceLayerIds;
  }

  void _validateStyleCompatibility({
    required Map<String, dynamic> styleJson,
    required _MbtilesMetadataInfo mbtilesMetadata,
  }) {
    if (mbtilesMetadata.vectorLayerIds.isEmpty) {
      return;
    }

    final styleSourceLayerIds = _extractSourceLayerIds(styleJson);
    if (styleSourceLayerIds.isEmpty) {
      return;
    }

    final matchedLayerCount = styleSourceLayerIds
        .where(mbtilesMetadata.vectorLayerIds.contains)
        .length;

    if (matchedLayerCount > 0) {
      return;
    }

    throw MbTilesException(
      'Style layers not compatible with MBTiles data.\n'
      'MBTiles layers: ${mbtilesMetadata.vectorLayerIds.join(', ')}\n'
      'Style layers: ${styleSourceLayerIds.join(', ')}',
      category: MapErrorCategory.styleLayerIncompatible,
    );
  }

  Set<String> _extractVectorLayerIdsFromMetadataJson(String metadataJson) {
    try {
      final decoded = jsonDecode(metadataJson);
      if (decoded is! Map<String, dynamic>) {
        return const <String>{};
      }

      final vectorLayers = decoded['vector_layers'];
      if (vectorLayers is! List) {
        return const <String>{};
      }

      final ids = <String>{};
      for (final layer in vectorLayers) {
        if (layer is! Map) {
          continue;
        }

        final id = layer['id'];
        if (id is String && id.isNotEmpty) {
          ids.add(id);
        }
      }

      return ids;
    } catch (_) {
      return const <String>{};
    }
  }

  Future<_MbtilesMetadataInfo> _readMbtilesMetadata(String path) async {
    if (!File(path).existsSync()) {
      return const _MbtilesMetadataInfo();
    }

    sqlite.Database? db;
    try {
      debugPrint('[map] Attempting to open metadata database: $path');
      db = sqlite.sqlite3.open(path, mode: sqlite.OpenMode.readOnly);
      final rows = db.select(
        "SELECT name, value FROM metadata WHERE name IN ('format', 'minzoom', 'maxzoom', 'json', 'bounds')",
      );

      String? format;
      double? minZoom;
      double? maxZoom;
      LatLngBounds? bounds;
      Set<String> vectorLayerIds = const <String>{};

      for (final row in rows) {
        final name = row['name'];
        final value = row['value'];

        if (name == 'format' && value is String) {
          format = value.toLowerCase();
        } else if (name == 'minzoom' && value != null) {
          minZoom = double.tryParse(value.toString());
        } else if (name == 'maxzoom' && value != null) {
          maxZoom = double.tryParse(value.toString());
        } else if (name == 'json' && value is String) {
          vectorLayerIds = _extractVectorLayerIdsFromMetadataJson(value);
        } else if (name == 'bounds' && value != null) {
          bounds = parseMbtilesBounds(value.toString());
        }
      }

      if (minZoom != null && maxZoom != null && minZoom > maxZoom) {
        final tmp = minZoom;
        minZoom = maxZoom;
        maxZoom = tmp;
      }

      return _MbtilesMetadataInfo(
        format: format,
        minZoom: minZoom,
        maxZoom: maxZoom,
        bounds: bounds,
        vectorLayerIds: vectorLayerIds,
      );
    } finally {
      db?.close();
    }
  }

  @override
  void didUpdateWidget(MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.config, widget.config)) {
      _config = widget.config ?? MapConfig.defaults;
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      (oldWidget.controller ?? _ownedController)?.detachView(this);
      if (widget.controller != null) {
        _ownedController?.dispose();
        _ownedController = null;
      }
      _mapReady = false;
      _controller.attachView(this);
    }
    if (oldWidget.mbtilesPath != widget.mbtilesPath) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
      _initializeTileProvider();
    }
  }

  @override
  void dispose() {
    _follow.dispose();
    _shown.dispose();
    _controller.detachView(this);
    _disposeTileResources();
    // Nur den selbst angelegten Controller entsorgen - ein uebergebener
    // gehoert dem Aufrufer.
    _ownedController?.dispose();
    _ownedController = null;
    super.dispose();
  }

  // --- LocalMapViewHandle ----------------------------------------------------

  /// Springt auf einen Suchtreffer, mit der Zoomstufe aus
  /// [MapConfig.searchResultZoom] statt der groben aus dem Geocoder.
  @override
  void moveToPlace(GeocoderResult place) {
    if (!_mapReady) return;
    _mapController.moveAndRotate(
      place.location,
      searchResultZoom(
        configured: _config.searchResultZoom,
        fromResult: place.zoom,
        min: _activeMinZoom,
        max: _activeMaxZoom,
      ),
      0.0,
    );
  }

  @override
  void fitRoute(List<LatLng> points) {
    if (!_mapReady || points.isEmpty) {
      return;
    }

    if (points.length == 1) {
      _mapController.move(points.first, _activeMaxZoom.clamp(14.0, 16.0));
      return;
    }

    final bounds = LatLngBounds.fromPoints(points);
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(44),
        maxZoom: _activeMaxZoom,
      ),
    );
  }

  /// Zoomt um [direction] Stufen und behaelt dabei die Bildmitte - wie die
  /// Kneifgeste, deren Brennpunktverankerung bewusst abgeschaltet ist.
  @override
  void stepZoom(int direction) {
    if (!_mapReady) return;
    final camera = _mapController.camera;
    final target = steppedZoom(
      current: camera.zoom,
      direction: direction,
      min: _activeMinZoom,
      max: _activeMaxZoom,
    );
    if (target == camera.zoom) {
      return;
    }
    _mapController.move(camera.center, target);
    _currentZoom = target;
    _controller.reportZoom(target);
  }

  @override
  Future<void> cycleVectorStyle() => _cycleVectorStyle();

  @override
  void positionChanged(PositionFix fix) {
    final target = _Pose(
      fix.position,
      _controller.heading ?? fix.headingDegrees ?? 0,
    );
    final from = _shown.value;
    // Weite Spruenge (Tour beginnt von vorn, erster Fix nach langer Pause)
    // nicht ueberblenden - die Kamera wuerde quer ueber die Karte fliegen.
    final jump =
        from != null &&
        const Distance().as(LengthUnit.Meter, from.position, target.position) >
            _maxBlendMeters;
    if (from == null || jump || widget.followAnimation == Duration.zero) {
      _follow.stop();
      _showPose(target);
      return;
    }
    _followFrom = from;
    _followTo = target;
    _follow.duration = widget.followAnimation;
    _follow.forward(from: 0);
  }

  @override
  void resetRotation() {
    if (!_mapReady) return;
    _mapController.rotate(0);
  }

  void _onFollowTick() {
    final from = _followFrom;
    final to = _followTo;
    if (from == null || to == null) return;
    _showPose(_Pose.lerp(from, to, _follow.value));
  }

  /// Setzt den Pfeil auf [pose] und fuehrt die Kamera nach, wenn sie folgt.
  void _showPose(_Pose pose) {
    _shown.value = pose;
    if (!_mapReady || !_controller.followPosition) return;

    final camera = _mapController.camera;
    final zoom = camera.zoom;
    if (!_controller.headingUp) {
      _mapController.move(pose.position, zoom);
      return;
    }

    // Fahrtrichtung oben: die Karte um -Kurs drehen (flutter_map dreht die
    // Ebenen im Uhrzeigersinn) und die Bildmitte in Fahrtrichtung vor das
    // Fahrzeug legen, damit es bei navigationAnchor steht. Gerechnet in
    // projizierten Pixeln, dort zeigt Norden nach oben und die Richtung ist
    // unabhaengig von der Drehung der Kamera.
    final ahead =
        (widget.navigationAnchor - 0.5) * camera.nonRotatedSize.height;
    final rad = pose.heading * math.pi / 180;
    final vehicle = camera.projectAtZoom(pose.position, zoom);
    final center = camera.unprojectAtZoom(
      vehicle + Offset(math.sin(rad), -math.cos(rad)) * ahead,
      zoom,
    );
    _mapController.moveAndRotate(center, zoom, -pose.heading);
  }

  // --- Darstellung -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final error = _error;
    if (error != null) {
      final builder = widget.errorBuilder;
      if (builder != null) {
        return builder(context, error);
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                error.userMessage,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      );
    }

    // Nach dem Frame, weil der Controller seine Zuhoerer benachrichtigt und
    // die mitten im Aufbau nicht neu bauen duerfen.
    WidgetsBinding.instance.addPostFrameCallback((_) => _publishMapState());

    return _buildMap(context);
  }

  Widget _buildMap(BuildContext context) {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        backgroundColor:
            widget.layerStyle.backgroundColor ?? const Color(0xFFE0E0E0),
        initialCenter: _initialCenter,
        initialZoom: _currentZoom,
        minZoom: _activeMinZoom,
        maxZoom: _activeMaxZoom,
        interactionOptions: const InteractionOptions(
          // Zwei Finger zoomen, sie verschieben und drehen nicht.
          //
          // flutter_map verankert den Zoom sonst am Brennpunkt zwischen den
          // Fingern (pinchMove). Das ist auf einer Weltkarte richtig, auf
          // einem kleinen Ausschnitt aber fatal: bei Zoom 11 ist ein
          // Bildpunkt rund 47 m breit, ein Griff 320 px neben der Mitte
          // verschiebt das Zentrum beim Hineinzoomen um ueber 10 km - auf
          // einem 7-Zoll-Schirm rutschen die Kacheln damit aus dem Bild.
          // Gemessen in pinch_gesture_test.dart.
          //
          // Drehen ist ebenfalls aus: zwei Finger stehen nie exakt parallel,
          // und eine versehentlich schief stehende Karte ist im Fahrzeug
          // nichts, was jemand haben will.
          //
          // Verschoben wird mit einem Finger, gezoomt zusaetzlich per
          // Doppeltipp und Mausrad.
          flags:
              InteractiveFlag.drag |
              InteractiveFlag.flingAnimation |
              InteractiveFlag.pinchZoom |
              InteractiveFlag.doubleTapZoom |
              InteractiveFlag.doubleTapDragZoom |
              InteractiveFlag.scrollWheelZoom,
          // Pfeiltasten schieben (Standard von flutter_map), R und F zoomen.
          // Auf einem Geraet ohne Zeigergeraet die einzige Moeglichkeit, die
          // Karte zu bewegen.
          keyboardOptions: KeyboardOptions(enableRFZooming: true),
        ),
        onMapReady: () {
          _mapReady = true;
          _controller.reportZoom(_mapController.camera.zoom);
        },
        onTap: (tapPosition, latLng) => _controller.clearHighlight(),
        // Wer die Karte mit dem Finger verschiebt, will woanders hinsehen -
        // der Folgemodus endet, bis der Gastgeber ihn wieder einschaltet.
        // Zoomen beendet ihn nicht.
        onMapEvent: (event) {
          if (event is MapEventMoveStart &&
              event.source == MapEventSource.dragStart) {
            _controller.followPosition = false;
          }
        },
        onPositionChanged: (camera, hasGesture) {
          if (!mounted) return;
          if ((camera.zoom - _currentZoom).abs() < 0.01) return;
          // Kein setState: die Karte baut sich selbst neu, und die Anzeigen
          // des Gastgebers haengen am Zoom des Controllers.
          _currentZoom = camera.zoom;
          _controller.reportZoom(camera.zoom);
        },
        // Begrenzt die Kamera, wenn die Konfiguration Bounds vorgibt
        // Ohne ausdrueckliche Vorgabe halten die Grenzen der MBTiles die
        // Kamera fest. Sonst schiebt man auf einem kleinen Ausschnitt mit
        // zwei Tastendruecken ins Leere und findet nicht zurueck.
        cameraConstraint: _activeCameraBounds == null
            ? const CameraConstraint.unconstrained()
            : CameraConstraint.containCenter(bounds: _activeCameraBounds!),
      ),
      children: [
        _buildTileLayer(context),
        // Die Ebenen darueber haengen einzeln am Controller. So baut eine
        // neue GPS-Position nur den Positionspfeil neu, nicht die Kacheln.
        _overlay(_buildHighlightLayer),
        _overlay(_buildRouteLayer),
        _overlay(_buildEndpointLayer),
        // Haengt an der Ueberblendung, nicht am Controller.
        _buildPositionLayer(context),
        // Quellenangabe. Sie liegt links unten, damit die Bedienelemente
        // des Gastgebers rechts sie nicht verdecken - sie muss sichtbar
        // bleiben.
        RichAttributionWidget(
          alignment: AttributionAlignment.bottomLeft,
          attributions: [
            TextSourceAttribution(
              '© OpenStreetMap contributors',
              onTap: () {
                // Optional: Link zu OSM Copyright-Seite öffnen
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _overlay(Widget Function(BuildContext context) builder) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => builder(context),
    );
  }

  Widget _buildTileLayer(BuildContext context) {
    if (_vectorTileProviders != null && _vectorTheme != null) {
      return VectorTileLayer(
        tileProviders: _vectorTileProviders!,
        theme: _vectorTheme!,
        sprites: _vectorSprites,
        maximumZoom: _activeMaxZoom,
        // Speicherbudget: ohne Angabe gelten die Defaults der Lib.
        memoryTileCacheMaxSize:
            _config.memoryTileCacheMaxSize ??
            VectorTileLayer.defaultTileCacheMaxSize,
        memoryTileDataCacheMaxSize:
            _config.memoryTileDataCacheMaxSize ??
            VectorTileLayer.defaultTileDataCacheMaxSize,
        textCacheMaxSize:
            _config.textCacheMaxSize ?? VectorTileLayer.defaultTextCacheMaxSize,
        concurrency:
            _config.vectorConcurrency ?? VectorTileLayer.defaultConcurrency,
        layerMode: _config.vectorLayerMode ?? VectorTileLayerMode.raster,
        panBuffer: _config.panBuffer,
        rasterTileScale:
            _config.rasterTileScale ?? MediaQuery.devicePixelRatioOf(context),
      );
    }
    return TileLayer(
      tileProvider: _rasterTileProvider,
      urlTemplate: _config.rasterUrlTemplate,
      maxZoom: _activeMaxZoom,
      errorTileCallback: (tile, error, stackTrace) {
        MapErrorHandler.logDebug(
          'Kachel $tile nicht geladen: $error',
          context: 'TileLayer',
        );
      },
    );
  }

  Widget _buildHighlightLayer(BuildContext context) {
    final place = _controller.highlightedPlace;
    if (place == null) return const SizedBox.shrink();
    return MarkerLayer(
      markers: [
        Marker(
          point: place.location,
          width: 48,
          height: 56,
          alignment: Alignment.topCenter,
          child: Tooltip(
            message: place.name,
            child: _PulsingTargetMarker(
              color:
                  widget.layerStyle.highlightColor ??
                  Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRouteLayer(BuildContext context) {
    final points = _controller.routePoints;
    if (points.isEmpty) return const SizedBox.shrink();
    return PolylineLayer(
      polylines: [
        Polyline(
          points: points,
          strokeWidth: widget.layerStyle.routeWidth,
          color:
              widget.layerStyle.routeColor ??
              Theme.of(context).colorScheme.primary,
        ),
      ],
    );
  }

  Widget _buildEndpointLayer(BuildContext context) {
    final start = _controller.start;
    final destination = _controller.destination;
    if (start == null && destination == null) return const SizedBox.shrink();
    return MarkerLayer(
      markers: [
        if (start != null)
          Marker(
            point: start.location,
            width: 44,
            height: 52,
            alignment: Alignment.topCenter,
            child: Tooltip(
              message: start.name,
              child: Icon(
                Icons.trip_origin,
                size: 28,
                color: widget.layerStyle.startColor ?? Colors.green.shade700,
              ),
            ),
          ),
        if (destination != null)
          Marker(
            point: destination.location,
            width: 44,
            height: 52,
            alignment: Alignment.topCenter,
            child: Tooltip(
              message: destination.name,
              child: Icon(
                Icons.flag,
                size: 30,
                color:
                    widget.layerStyle.destinationColor ?? Colors.red.shade700,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPositionLayer(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<_Pose?>(
      valueListenable: _shown,
      builder: (context, pose, _) {
        if (pose == null) return const SizedBox.shrink();
        return MarkerLayer(
          markers: [
            Marker(
              point: pose.position,
              width: 42,
              height: 42,
              // Dreht mit der Karte: der Pfeil zeigt in Kartenrichtung den
              // Kurs, bei Fahrtrichtung oben also nach oben.
              rotate: false,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: widget.layerStyle.positionColor ?? colorScheme.primary,
                  shape: BoxShape.circle,
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x44000000),
                      blurRadius: 8,
                      offset: Offset(0, 3),
                    ),
                  ],
                ),
                child: Transform.rotate(
                  angle: pose.heading * math.pi / 180,
                  child: Icon(
                    Icons.navigation,
                    size: 20,
                    color:
                        widget.layerStyle.onPositionColor ??
                        colorScheme.onPrimary,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MbtilesMetadataInfo {
  final String? format;
  final double? minZoom;
  final double? maxZoom;

  /// Abdeckung der Kacheln, aus dem `bounds`-Eintrag der MBTiles-Metadaten.
  /// `null`, wenn die Datei keinen (gueltigen) Eintrag hat.
  final LatLngBounds? bounds;
  final Set<String> vectorLayerIds;

  const _MbtilesMetadataInfo({
    this.format,
    this.minZoom,
    this.maxZoom,
    this.bounds,
    this.vectorLayerIds = const <String>{},
  });
}

class _LocalVectorStyleLoadResult {
  final vtr.Theme theme;
  final SpriteStyle? sprites;
  final TileProviders tileProviders;
  final String assetPath;

  const _LocalVectorStyleLoadResult({
    required this.theme,
    required this.sprites,
    required this.tileProviders,
    required this.assetPath,
  });
}

class _PulsingTargetMarker extends StatefulWidget {
  final Color color;

  const _PulsingTargetMarker({required this.color});

  @override
  State<_PulsingTargetMarker> createState() => _PulsingTargetMarkerState();
}

class _PulsingTargetMarkerState extends State<_PulsingTargetMarker> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(
        begin: _expanded ? 0.92 : 1.0,
        end: _expanded ? 1.0 : 0.92,
      ),
      duration: const Duration(milliseconds: 850),
      curve: Curves.easeInOut,
      onEnd: () {
        if (!mounted) {
          return;
        }
        setState(() {
          _expanded = !_expanded;
        });
      },
      child: Icon(Icons.location_on, color: widget.color, size: 44),
      builder: (context, scale, child) {
        return Transform.scale(scale: scale, child: child);
      },
    );
  }
}

/// Position und Kurs, wie sie der Pfeil gerade zeigt.
class _Pose {
  final LatLng position;
  final double heading;

  const _Pose(this.position, this.heading);

  static _Pose lerp(_Pose a, _Pose b, double t) => _Pose(
    LatLng(
      a.position.latitude + (b.position.latitude - a.position.latitude) * t,
      a.position.longitude + (b.position.longitude - a.position.longitude) * t,
    ),
    (a.heading + shortestTurn(a.heading, b.heading) * t) % 360,
  );
}
