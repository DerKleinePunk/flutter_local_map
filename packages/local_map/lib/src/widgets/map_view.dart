import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:mbtiles/mbtiles.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_mbtiles/vector_map_tiles_mbtiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;
import '../config/map_config.dart';
import '../services/gps_nmea_simulator_service.dart';
import '../services/map_camera_bounds.dart';
import '../services/map_error_handler.dart';
import '../services/offline_geocoder.dart';
import '../services/valhalla_routing_service.dart';
import 'search_bar.dart';

/// Widget zur Darstellung der Karte mit MBTiles
class MapView extends StatefulWidget {
  /// Pfad zur MBTiles-Datei (Raster oder Vektor/pbf).
  final String? mbtilesPath;

  /// Zoom-Grenzen, Kartenmittelpunkt, Vektorstyles, Valhalla-Endpunkt usw.
  /// Ohne Angabe wird [MapConfig.defaults] verwendet.
  final MapConfig? config;

  /// Optionaler externer Controller, um die Kamera von aussen zu steuern.
  /// Ohne Angabe verwaltet [MapView] einen eigenen Controller.
  final MapController? mapController;

  const MapView({
    super.key,
    this.mbtilesPath,
    this.config,
    this.mapController,
  });

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  static const Set<String> _knownVectorSourceAliases = {
    'openmaptiles',
    'versatiles-shortbread',
    'shortbread',
  };

  /// Eigener Controller, nur angelegt wenn keiner uebergeben wurde.
  MapController? _ownedMapController;
  MapController get _mapController =>
      widget.mapController ??
      (_ownedMapController ??= MapController());

  final OfflineGeocoder _geocoder = OfflineGeocoder();
  final GpsNmeaSimulatorService _gpsSimulator = GpsNmeaSimulatorService();

  /// Aktive Konfiguration, in [initState] aus dem Widget uebernommen.
  late MapConfig _config;
  late final ValhallaRoutingService _routingService;
  StreamSubscription<SimulatedGpsFix>? _gpsFixSubscription;

  /// Token to track initialization requests and prevent race conditions.
  /// Incremented each time _initializeTileProvider is called.
  int _initializationToken = 0;

  /// ValueNotifier for zoom level to decouple badge updates from map rebuilds.
  /// This allows the zoom badge to update independently without triggering full map redraws.
  late final ValueNotifier<double> _zoomNotifier;

  MbTilesTileProvider? _rasterTileProvider;
  MbTiles? _vectorMbTiles;
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
  GeocoderResult? _selectedSearchResult;
  GeocoderResult? _routeStart;
  GeocoderResult? _routeEnd;
  List<LatLng> _routePolyline = const <LatLng>[];
  bool _isRouting = false;
  bool _isRoutingAvailable = false;
  String? _routingMessage;
  LatLng? _gpsSimPosition;
  bool _isGpsSimRunning = false;
  bool _followSimulatedGps = true;
  int _gpsLoadedFixes = 0;
  String? _gpsSimMessage;
  double? _routeDistanceMeters;
  int? _routeDurationSeconds;
  bool _isLoading = true;
  String? _errorMessage;

  static const Set<String> _rasterFormats = {'png', 'jpg', 'jpeg', 'webp'};

  List<String> get _localVectorStyleAssets => _config.vectorStyleAssets;

  bool get _isVectorMode =>
      _vectorTileProviders != null && _vectorTheme != null;

  @override
  void initState() {
    super.initState();
    _config = widget.config ?? MapConfig.defaults;
    _routingService = ValhallaRoutingService(
      baseUri: _config.valhallaBaseUri,
    );
    _activeMinZoom = _config.minZoom;
    _activeMaxZoom = _config.maxZoom;
    _currentZoom = _config.initialZoom;
    _initialCenter = _config.center;
    _activeCameraBounds = _config.cameraBounds;
    _selectedVectorStyleAssetIndex = _localVectorStyleAssets.isEmpty
        ? 0
        : _config.initialVectorStyleIndex % _localVectorStyleAssets.length;
    _zoomNotifier = ValueNotifier<double>(_currentZoom);
    _initializeTileProvider();
    _initializeGeocoder();
    _checkRoutingAvailability();
    _gpsFixSubscription = _gpsSimulator.fixes.listen(_onSimulatedGpsFix);
  }

  Future<void> _initializeGpsSimulator() async {
    try {
      final loaded = await _gpsSimulator.loadDefaultTourFile(
        candidatePaths: _config.gpsTourFilePaths,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _gpsLoadedFixes = loaded;
        _gpsSimMessage = null;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _gpsLoadedFixes = 0;
        _gpsSimMessage = e.toString();
      });
    }
  }

  void _onSimulatedGpsFix(SimulatedGpsFix fix) {
    if (!mounted) {
      return;
    }

    setState(() {
      _gpsSimPosition = fix.position;
    });

    if (_followSimulatedGps) {
      _mapController.move(fix.position, _currentZoom);
    }
  }

  Future<void> _toggleGpsSimulation() async {
    if (_isGpsSimRunning) {
      _gpsSimulator.stop();
      if (!mounted) {
        return;
      }
      setState(() {
        _isGpsSimRunning = false;
      });
      return;
    }

    if (!_gpsSimulator.hasData) {
      await _initializeGpsSimulator();
      if (!_gpsSimulator.hasData) {
        return;
      }
    }

    try {
      _gpsSimulator.start(interval: const Duration(seconds: 5), loop: true);
      if (!mounted) {
        return;
      }
      setState(() {
        _isGpsSimRunning = true;
        _gpsSimMessage = null;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isGpsSimRunning = false;
        _gpsSimMessage = e.toString();
      });
    }
  }

  Future<void> _checkRoutingAvailability() async {
    final available = await _routingService.isAvailable();
    if (!mounted) {
      return;
    }
    setState(() {
      _isRoutingAvailable = available;
      _routingMessage = available
          ? null
          : 'Valhalla nicht erreichbar (127.0.0.1:8002).';
    });
  }

  Future<void> _tryBuildRoute() async {
    if (_routeStart == null || _routeEnd == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _routePolyline = const <LatLng>[];
        _routeDistanceMeters = null;
        _routeDurationSeconds = null;
      });
      return;
    }

    setState(() {
      _isRouting = true;
      _routingMessage = null;
    });

    try {
      final result = await _routingService.route(
        start: _routeStart!.location,
        end: _routeEnd!.location,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _isRoutingAvailable = true;
        _routePolyline = result.geometry
            .map((point) => point.toLatLng())
            .toList();
        _routeDistanceMeters = result.distanceMeters;
        _routeDurationSeconds = result.durationSeconds;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _fitCameraToRoute(_routePolyline);
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isRoutingAvailable = false;
        _routePolyline = const <LatLng>[];
        _routeDistanceMeters = null;
        _routeDurationSeconds = null;
        _routingMessage = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isRouting = false;
        });
      }
    }
  }

  void _fitCameraToRoute(List<LatLng> points) {
    if (points.isEmpty) {
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

  String _formatRouteSummary() {
    if (_routeDistanceMeters == null || _routeDurationSeconds == null) {
      return 'Route bereit';
    }

    final distanceKm = _routeDistanceMeters! / 1000;
    final durationMin = (_routeDurationSeconds! / 60).round();
    return '${distanceKm.toStringAsFixed(1)} km • $durationMin min';
  }

  Future<void> _initializeGeocoder() async {
    // Try to initialize with vogelsberg names database first
    final namesDbPath = widget.mbtilesPath?.replaceAll('.mbtiles', '_names.db');

    if (namesDbPath != null &&
        namesDbPath.isNotEmpty &&
        File(namesDbPath).existsSync()) {
      final success = await _geocoder.initialize(namesDbPath);
      if (success && mounted) {
        debugPrint('[map] Geocoder initialized with $namesDbPath');
      } else if (mounted) {
        debugPrint('[map] Failed to initialize geocoder with $namesDbPath');
      }
    } else {
      debugPrint('[map] Names database not found at $namesDbPath');
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
        _errorMessage = 'Keine Kartendaten verfügbar';
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
          _errorMessage = null;
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
          _errorMessage = error.userMessage;
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
        _errorMessage = null;
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
        _errorMessage = mapError.userMessage;
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

        MapErrorHandler.logDebug(
          'Style loaded successfully: ${theme.layers.length} layers',
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

    setState(() {
      _selectedVectorStyleAssetIndex =
          (_selectedVectorStyleAssetIndex + 1) % _localVectorStyleAssets.length;
      _isLoading = true;
      _errorMessage = null;
    });

    await _initializeTileProvider();
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
    if (oldWidget.mbtilesPath != widget.mbtilesPath) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
      _initializeTileProvider();
    }
  }

  @override
  void dispose() {
    _gpsFixSubscription?.cancel();
    _gpsSimulator.dispose();
    _disposeTileResources();
    // Nur den selbst angelegten Controller entsorgen - ein uebergebener
    // gehoert dem Aufrufer.
    _ownedMapController?.dispose();
    _ownedMapController = null;
    _geocoder.close();
    _zoomNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      );
    }

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
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
          flags: InteractiveFlag.drag |
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
        onTap: (tapPosition, latLng) {
          if (_selectedSearchResult == null || !mounted) {
            return;
          }
          setState(() {
            _selectedSearchResult = null;
          });
        },
        onPositionChanged: (camera, hasGesture) {
          if (!mounted) return;
          if ((camera.zoom - _currentZoom).abs() < 0.01) return;
          // Update internal state without setState to avoid map rebuild
          _currentZoom = camera.zoom;
          // Update zoom notifier to trigger badge update
          _zoomNotifier.value = camera.zoom;
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
        if (_vectorTileProviders != null && _vectorTheme != null)
          VectorTileLayer(
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
                _config.textCacheMaxSize ??
                VectorTileLayer.defaultTextCacheMaxSize,
            concurrency:
                _config.vectorConcurrency ?? VectorTileLayer.defaultConcurrency,
            layerMode:
                _config.vectorLayerMode ?? VectorTileLayerMode.raster,
          )
        else
          TileLayer(
            tileProvider: _rasterTileProvider,
            urlTemplate: _config.rasterUrlTemplate,
            maxZoom: _activeMaxZoom,
            // Platzhalter für nicht geladene Tiles
            errorTileCallback: (tile, error, stackTrace) {
              debugPrint('Fehler beim Laden von Tile $tile: $error');
            },
          ),
        if (_selectedSearchResult != null)
          MarkerLayer(
            markers: [
              Marker(
                point: _selectedSearchResult!.location,
                width: 48,
                height: 56,
                alignment: Alignment.topCenter,
                child: Tooltip(
                  message: _selectedSearchResult!.name,
                  child: _PulsingTargetMarker(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        if (_routePolyline.isNotEmpty)
          PolylineLayer(
            polylines: [
              Polyline(
                points: _routePolyline,
                strokeWidth: 5,
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
        if (_routeStart != null || _routeEnd != null)
          MarkerLayer(
            markers: [
              if (_routeStart != null)
                Marker(
                  point: _routeStart!.location,
                  width: 44,
                  height: 52,
                  alignment: Alignment.topCenter,
                  child: Tooltip(
                    message: 'Start: ${_routeStart!.name}',
                    child: Icon(
                      Icons.trip_origin,
                      size: 28,
                      color: Colors.green.shade700,
                    ),
                  ),
                ),
              if (_routeEnd != null)
                Marker(
                  point: _routeEnd!.location,
                  width: 44,
                  height: 52,
                  alignment: Alignment.topCenter,
                  child: Tooltip(
                    message: 'Ziel: ${_routeEnd!.name}',
                    child: Icon(
                      Icons.flag,
                      size: 30,
                      color: Colors.red.shade700,
                    ),
                  ),
                ),
            ],
          ),
        if (_gpsSimPosition != null)
          MarkerLayer(
            markers: [
              Marker(
                point: _gpsSimPosition!,
                width: 42,
                height: 42,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x44000000),
                        blurRadius: 8,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.navigation,
                    size: 20,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
              ),
            ],
          ),
        // Attribution Layer
        RichAttributionWidget(
          attributions: [
            TextSourceAttribution(
              '© OpenStreetMap contributors',
              onTap: () {
                // Optional: Link zu OSM Copyright-Seite öffnen
              },
            ),
          ],
        ),
        // Search Bar
        if (_geocoder.isInitialized)
          Positioned(
            top: 12,
            left: 200,
            right: 200,
            child: Column(
              children: [
                PlaceSearchBar(
                  mapController: _mapController,
                  geocoder: _geocoder,
                  initialZoom: _currentZoom,
                  hintText: 'Start suchen...',
                  prefixIcon: Icons.trip_origin,
                  onClearSearch: () {
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      _routeStart = null;
                    });
                    _tryBuildRoute();
                  },
                  onPlaceSelected: (result) {
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      _selectedSearchResult = result;
                      _routeStart = result;
                    });
                    _tryBuildRoute();
                  },
                ),
                PlaceSearchBar(
                  mapController: _mapController,
                  geocoder: _geocoder,
                  initialZoom: _currentZoom,
                  hintText: 'Ziel suchen...',
                  prefixIcon: Icons.flag,
                  onClearSearch: () {
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      _routeEnd = null;
                    });
                    _tryBuildRoute();
                  },
                  onPlaceSelected: (result) {
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      _selectedSearchResult = result;
                      _routeEnd = result;
                    });
                    _tryBuildRoute();
                  },
                ),
              ],
            ),
          ),
        Positioned(
          top: 112,
          left: 12,
          child: IgnorePointer(child: _buildRoutingBadge(context)),
        ),
        Positioned(
          top: 12,
          left: 12,
          child: IgnorePointer(
            child: _ZoomBadgeWidget(zoomNotifier: _zoomNotifier),
          ),
        ),
        Positioned(
          top: 12,
          right: 12,
          child: IgnorePointer(child: _buildModeBadge(context)),
        ),
        if (_isVectorMode)
          Positioned(top: 48, right: 12, child: _buildStyleSwitchChip(context)),
        Positioned(top: 84, right: 12, child: _buildGpsSimulatorChip(context)),
        Positioned(
          bottom: 16,
          right: 12,
          child: _buildZoomButtons(context),
        ),
      ],
    );
  }

  /// Zoomknoepfe fuer die Bedienung mit dem Finger.
  ///
  /// Auf einem kleinen Fahrzeugdisplay ist die Kneifgeste unpraktisch - sie
  /// braucht zwei Finger und eine ruhige Hand. Die Knoepfe sind 56 px gross,
  /// damit sie mit dem Daumen sicher zu treffen sind.
  Widget _buildZoomButtons(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ValueListenableBuilder<double>(
      valueListenable: _zoomNotifier,
      builder: (context, zoom, _) {
        return Material(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ZoomButton(
                icon: Icons.add,
                tooltip: 'Hineinzoomen',
                // Am Anschlag abgeschaltet, damit der Knopf nicht wirkungslos
                // gedrueckt wird.
                onPressed: zoom < _activeMaxZoom ? () => _stepZoom(1) : null,
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: colorScheme.outlineVariant,
              ),
              _ZoomButton(
                icon: Icons.remove,
                tooltip: 'Herauszoomen',
                onPressed: zoom > _activeMinZoom ? () => _stepZoom(-1) : null,
              ),
            ],
          ),
        );
      },
    );
  }

  /// Zoomt um [direction] Stufen und behaelt dabei die Bildmitte - wie die
  /// Kneifgeste, deren Brennpunktverankerung bewusst abgeschaltet ist.
  void _stepZoom(int direction) {
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
    _zoomNotifier.value = target;
  }

  Widget _buildGpsSimulatorChip(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isRunning = _isGpsSimRunning;
    final statusLabel = _gpsLoadedFixes > 0
        ? 'GPS Sim ${isRunning ? 'an' : 'aus'} ($_gpsLoadedFixes)'
        : (_gpsSimMessage ?? 'GPS Sim laden');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: _toggleGpsSimulation,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isRunning
                ? colorScheme.primaryContainer
                : colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isRunning ? Icons.stop_circle_outlined : Icons.play_circle,
                  size: 14,
                  color: isRunning
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 6),
                Text(
                  statusLabel,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: isRunning
                        ? colorScheme.onPrimaryContainer
                        : colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _followSimulatedGps = !_followSimulatedGps;
                    });
                  },
                  child: Icon(
                    _followSimulatedGps
                        ? Icons.my_location
                        : Icons.location_disabled,
                    size: 14,
                    color: isRunning
                        ? colorScheme.onPrimaryContainer
                        : colorScheme.onSecondaryContainer,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStyleSwitchChip(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: _cycleVectorStyle,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.palette_outlined,
                  size: 14,
                  color: colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 6),
                Text(
                  _activeVectorStyleLabel(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeBadge(BuildContext context) {
    final isVector = _isVectorMode;
    final colorScheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: isVector
            ? colorScheme.tertiaryContainer
            : colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isVector ? Icons.layers : Icons.grid_on,
              size: 14,
              color: isVector
                  ? colorScheme.onTertiaryContainer
                  : colorScheme.onPrimaryContainer,
            ),
            const SizedBox(width: 6),
            Text(
              isVector ? 'Vektor MBTiles (PBF)' : 'Raster MBTiles',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: isVector
                    ? colorScheme.onTertiaryContainer
                    : colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoutingBadge(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasRoute = _routePolyline.isNotEmpty;

    final Color bgColor;
    final Color fgColor;
    final String label;
    final IconData icon;

    if (_isRouting) {
      bgColor = colorScheme.tertiaryContainer;
      fgColor = colorScheme.onTertiaryContainer;
      label = 'Route wird berechnet...';
      icon = Icons.sync;
    } else if (hasRoute) {
      bgColor = colorScheme.primaryContainer;
      fgColor = colorScheme.onPrimaryContainer;
      label = _formatRouteSummary();
      icon = Icons.route;
    } else if (_routingMessage != null) {
      bgColor = colorScheme.errorContainer;
      fgColor = colorScheme.onErrorContainer;
      label = _routingMessage!;
      icon = Icons.warning_amber_rounded;
    } else if (_isRoutingAvailable) {
      bgColor = colorScheme.secondaryContainer;
      fgColor = colorScheme.onSecondaryContainer;
      label = 'Routing bereit';
      icon = Icons.route;
    } else {
      bgColor = colorScheme.errorContainer;
      fgColor = colorScheme.onErrorContainer;
      label = 'Valhalla offline';
      icon = Icons.cloud_off;
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fgColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: fgColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
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

/// Separate widget for zoom badge that updates independently without triggering map rebuilds.
/// Uses ValueListenableBuilder to listen to zoom changes without setState.
class _ZoomButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _ZoomButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: 56,
          height: 56,
          child: Icon(
            icon,
            size: 28,
            color: enabled
                ? colorScheme.onSurface
                : colorScheme.onSurface.withValues(alpha: 0.3),
          ),
        ),
      ),
    );
  }
}

class _ZoomBadgeWidget extends StatelessWidget {
  final ValueNotifier<double> zoomNotifier;

  const _ZoomBadgeWidget({required this.zoomNotifier});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ValueListenableBuilder<double>(
      valueListenable: zoomNotifier,
      builder: (context, zoom, _) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.zoom_in,
                  size: 14,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  'Zoom ${zoom.toStringAsFixed(1)}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
