import 'dart:io';
import 'dart:convert';

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

/// Widget zur Darstellung der Karte mit MBTiles
class MapView extends StatefulWidget {
  final String? mbtilesPath;

  const MapView({super.key, this.mbtilesPath});

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  static const Set<String> _knownVectorSourceAliases = {
    'openmaptiles',
    'versatiles-shortbread',
    'shortbread',
  };

  final MapController _mapController = MapController();
  MbTilesTileProvider? _rasterTileProvider;
  MbTiles? _vectorMbTiles;
  TileProviders? _vectorTileProviders;
  vtr.Theme? _vectorTheme;
  SpriteStyle? _vectorSprites;
  double _activeMinZoom = MapConfig.minZoom.toDouble();
  double _activeMaxZoom = MapConfig.maxZoom.toDouble();
  double _currentZoom = MapConfig.initialZoom.toDouble();
  int _selectedVectorStyleAssetIndex = 2;
  String? _activeVectorStyleAssetPath;
  bool _isLoading = true;
  String? _errorMessage;

  static const Set<String> _rasterFormats = {'png', 'jpg', 'jpeg', 'webp'};
  static const List<String> _localVectorStyleAssets = [
    'assets/maps/style.json',
    'assets/maps/style_second.json',
    'assets/maps/style_navigation.json',
  ];

  bool get _isVectorMode =>
      _vectorTileProviders != null && _vectorTheme != null;

  @override
  void initState() {
    super.initState();
    _initializeTileProvider();
  }

  Future<void> _initializeTileProvider() async {
    _disposeTileResources();

    if (widget.mbtilesPath == null) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Keine Kartendaten verfügbar';
      });
      return;
    }

    try {
      final metadata = await _readMbtilesMetadata(widget.mbtilesPath!);
      final format = metadata.format;
      final minZoom = metadata.minZoom ?? MapConfig.minZoom.toDouble();
      final maxZoom = metadata.maxZoom ?? MapConfig.maxZoom.toDouble();
      final boundedInitialZoom = MapConfig.initialZoom.toDouble().clamp(
        minZoom,
        maxZoom,
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
        } catch (assetError) {
          debugPrint('Lokale Styles fehlgeschlagen: $assetError');
          debugPrint('Verwende Fallback-Theme ohne Labels');
          vectorTheme = vtr.ProvidedThemes.lightTheme();
          vectorSprites = null;
          vectorTileProviders = _buildFallbackVectorTileProviders(provider);
          _activeVectorStyleAssetPath = null;
        }

        if (!mounted) {
          mbtiles.close();
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
          _isLoading = false;
          _errorMessage = null;
        });
        return;
      }

      if (format != null && !_rasterFormats.contains(format)) {
        setState(() {
          _isLoading = false;
          _errorMessage =
              'Nicht unterstütztes MBTiles-Format: $format. '
              'Erwartet werden Raster (png/jpg/webp) oder Vektor (pbf).';
        });
        return;
      }

      final provider = MbTilesTileProvider.fromPath(path: widget.mbtilesPath!);

      if (!mounted) {
        provider.dispose();
        return;
      }

      setState(() {
        _rasterTileProvider = provider;
        _activeMinZoom = minZoom;
        _activeMaxZoom = maxZoom;
        _currentZoom = boundedInitialZoom;
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Fehler beim Laden der Kartendaten: $e';
      });
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

    _activeMinZoom = MapConfig.minZoom.toDouble();
    _activeMaxZoom = MapConfig.maxZoom.toDouble();
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
      throw StateError('Lokaler Style enthält keine Tile-Quellen.');
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

    for (final styleAssetPath in _orderedLocalStyleAssets()) {
      try {
        debugPrint('Lade lokalen Asset-Style: $styleAssetPath');

        final styleText = await rootBundle.loadString(styleAssetPath);
        final decoded = jsonDecode(styleText);

        if (decoded is! Map<String, dynamic>) {
          throw StateError('Lokaler Style ist kein JSON-Objekt.');
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

        debugPrint(
          'Lokaler Asset-Style geladen ($styleAssetPath): ${theme.layers.length} Layer, Sources: ${tileProviders.tileProviderBySource.keys.join(', ')}',
        );

        return _LocalVectorStyleLoadResult(
          theme: theme,
          sprites: null,
          tileProviders: tileProviders,
          assetPath: styleAssetPath,
        );
      } catch (error) {
        lastError = error;
        debugPrint(
          'Lokaler Asset-Style fehlgeschlagen ($styleAssetPath): $error',
        );
      }
    }

    throw StateError(
      'Kein lokaler Vektor-Style konnte geladen werden. Letzter Fehler: $lastError',
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

    throw StateError(
      'Lokaler Style ist nicht mit dem MBTiles-Schema kompatibel. '
      'MBTiles-Layer: ${mbtilesMetadata.vectorLayerIds.join(', ')}, '
      'Style-Layer: ${styleSourceLayerIds.join(', ')}',
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
      db = sqlite.sqlite3.open(path, mode: sqlite.OpenMode.readOnly);
      final rows = db.select(
        "SELECT name, value FROM metadata WHERE name IN ('format', 'minzoom', 'maxzoom', 'json')",
      );

      String? format;
      double? minZoom;
      double? maxZoom;
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
        vectorLayerIds: vectorLayerIds,
      );
    } finally {
      db?.close();
    }
  }

  @override
  void didUpdateWidget(MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    _disposeTileResources();
    _mapController.dispose();
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
        initialCenter: MapConfig.center,
        initialZoom: _currentZoom,
        minZoom: _activeMinZoom,
        maxZoom: _activeMaxZoom,
        onPositionChanged: (camera, hasGesture) {
          if (!mounted) return;
          if ((camera.zoom - _currentZoom).abs() < 0.01) return;
          setState(() {
            _currentZoom = camera.zoom;
          });
        },
        // Begrenze die Kamera auf die Hessen-Bounding-Box
        cameraConstraint: CameraConstraint.containCenter(
          bounds: MapConfig.hessenBounds,
        ),
      ),
      children: [
        if (_vectorTileProviders != null && _vectorTheme != null)
          VectorTileLayer(
            tileProviders: _vectorTileProviders!,
            theme: _vectorTheme!,
            sprites: _vectorSprites,
            maximumZoom: _activeMaxZoom,
          )
        else
          TileLayer(
            tileProvider: _rasterTileProvider,
            urlTemplate: 'mbtiles://hessen',
            maxZoom: _activeMaxZoom,
            // Platzhalter für nicht geladene Tiles
            errorTileCallback: (tile, error, stackTrace) {
              debugPrint('Fehler beim Laden von Tile $tile: $error');
            },
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
        Positioned(
          top: 12,
          left: 12,
          child: IgnorePointer(child: _buildZoomBadge(context)),
        ),
        Positioned(
          top: 12,
          right: 12,
          child: IgnorePointer(child: _buildModeBadge(context)),
        ),
        if (_isVectorMode)
          Positioned(top: 48, right: 12, child: _buildStyleSwitchChip(context)),
      ],
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

  Widget _buildZoomBadge(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

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
            Icon(Icons.zoom_in, size: 14, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              'Zoom ${_currentZoom.toStringAsFixed(1)}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
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
  final Set<String> vectorLayerIds;

  const _MbtilesMetadataInfo({
    this.format,
    this.minZoom,
    this.maxZoom,
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
