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
  final MapController _mapController = MapController();
  MbTilesTileProvider? _rasterTileProvider;
  MbTiles? _vectorMbTiles;
  TileProviders? _vectorTileProviders;
  vtr.Theme? _vectorTheme;
  SpriteStyle? _vectorSprites;
  double _activeMinZoom = MapConfig.minZoom.toDouble();
  double _activeMaxZoom = MapConfig.maxZoom.toDouble();
  double _currentZoom = MapConfig.initialZoom.toDouble();
  bool _isLoading = true;
  String? _errorMessage;

  static const Set<String> _rasterFormats = {'png', 'jpg', 'jpeg', 'webp'};
  static const String _defaultVectorStyleUri =
      'https://maputnik.github.io/osm-liberty/style.json';
  static const String _localVectorStyleAsset = 'assets/maps/style.json';

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
      final boundedInitialZoom =
          MapConfig.initialZoom.toDouble().clamp(minZoom, maxZoom);

      if (format == 'pbf') {
        final mbtiles = MbTiles(path: widget.mbtilesPath!);
        final provider = MbTilesVectorTileProvider(mbtiles: mbtiles);

        vtr.Theme vectorTheme;
        SpriteStyle? vectorSprites;
        TileProviders vectorTileProviders;

        try {
          debugPrint('Lade Remote-Style von: $_defaultVectorStyleUri');
          final style = await StyleReader(uri: _defaultVectorStyleUri).read();
          final providerBySource = <String, VectorTileProvider>{
            for (final sourceId in style.providers.tileProviderBySource.keys)
              sourceId: provider,
          };

          if (providerBySource.isEmpty) {
            throw StateError('Style enthält keine Tile-Quellen.');
          }

          providerBySource.addAll({
              'openmaptiles': provider,
          });

          vectorTheme = style.theme;
          vectorSprites = style.sprites;
          vectorTileProviders = TileProviders(providerBySource);
          debugPrint(
            'Remote-Style geladen: ${style.theme.layers.length} Layer, Sprites: ${style.sprites != null}',
          );
        } catch (e) {
          debugPrint('Remote-Style fehlgeschlagen: $e');
          debugPrint('Versuche lokalen Asset-Style: $_localVectorStyleAsset');

          try {
            final styleText = await rootBundle.loadString(_localVectorStyleAsset);
            final decoded = jsonDecode(styleText);

            if (decoded is! Map<String, dynamic>) {
              throw StateError('Lokaler Style ist kein JSON-Objekt.');
            }

            final sources = decoded['sources'];
            if (sources is! Map<String, dynamic> || sources.isEmpty) {
              throw StateError('Lokaler Style enthält keine Sources.');
            }

            vectorTheme = vtr.ThemeReader(logger: const vtr.Logger.noop()).read(
              decoded,
            );
            vectorSprites = null;
            vectorTileProviders = TileProviders({
              for (final sourceId in sources.keys) sourceId: provider,
            });

            vectorTileProviders.tileProviderBySource.addAll({
              'openmaptiles': provider,
              'versatiles-shortbread': provider,
              'shortbread': provider,
            });
            debugPrint(
              'Lokaler Asset-Style geladen: ${vectorTheme.layers.length} Layer, Sources: ${sources.keys.join(', ')}',
            );
          } catch (assetError) {
            debugPrint('Lokaler Asset-Style fehlgeschlagen: $assetError');
            debugPrint('Verwende Fallback-Theme ohne Labels');
            vectorTheme = vtr.ProvidedThemes.lightTheme();
            vectorSprites = null;
            vectorTileProviders = TileProviders({
              'openmaptiles': provider,
              'versatiles-shortbread': provider,
              'shortbread': provider,
            });
          }
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

  Future<_MbtilesMetadataInfo> _readMbtilesMetadata(String path) async {
    if (!File(path).existsSync()) {
      return const _MbtilesMetadataInfo();
    }

    sqlite.Database? db;
    try {
      db = sqlite.sqlite3.open(path, mode: sqlite.OpenMode.readOnly);
      final rows = db.select(
        "SELECT name, value FROM metadata WHERE name IN ('format', 'minzoom', 'maxzoom')",
      );

      String? format;
      double? minZoom;
      double? maxZoom;

      for (final row in rows) {
        final name = row['name'];
        final value = row['value'];

        if (name == 'format' && value is String) {
          format = value.toLowerCase();
        } else if (name == 'minzoom' && value != null) {
          minZoom = double.tryParse(value.toString());
        } else if (name == 'maxzoom' && value != null) {
          maxZoom = double.tryParse(value.toString());
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
      ],
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

  const _MbtilesMetadataInfo({
    this.format,
    this.minZoom,
    this.maxZoom,
  });
}
