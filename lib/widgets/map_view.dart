import 'dart:io';

import 'package:flutter/material.dart';
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
  bool _isLoading = true;
  String? _errorMessage;

  static const Set<String> _rasterFormats = {'png', 'jpg', 'jpeg', 'webp'};

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
      final format = await _readMbtilesFormat(widget.mbtilesPath!);

      if (format == 'pbf') {
        final mbtiles = MbTiles(path: widget.mbtilesPath!);
        final provider = MbTilesVectorTileProvider(mbtiles: mbtiles);

        if (!mounted) {
          mbtiles.close();
          return;
        }

        setState(() {
          _vectorMbTiles = mbtiles;
          _vectorTheme = vtr.ProvidedThemes.lightTheme();
          // Mehrere Source-IDs verbessern die Kompatibilitaet unterschiedlicher Styles.
          _vectorTileProviders = TileProviders({
            'openmaptiles': provider,
            'versatiles-shortbread': provider,
            'shortbread': provider,
          });
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
  }

  Future<String?> _readMbtilesFormat(String path) async {
    if (!File(path).existsSync()) {
      return null;
    }

    sqlite.Database? db;
    try {
      db = sqlite.sqlite3.open(path, mode: sqlite.OpenMode.readOnly);
      final result = db.select(
        "SELECT value FROM metadata WHERE name = 'format' LIMIT 1",
      );

      if (result.isEmpty) {
        return null;
      }

      final value = result.first['value'];
      if (value is String) {
        return value.toLowerCase();
      }

      return null;
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
        initialZoom: MapConfig.initialZoom.toDouble(),
        minZoom: MapConfig.minZoom.toDouble(),
        maxZoom: MapConfig.maxZoom.toDouble(),
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
            maximumZoom: MapConfig.maxZoom.toDouble(),
          )
        else
          TileLayer(
            tileProvider: _rasterTileProvider,
            urlTemplate: 'mbtiles://hessen',
            maxZoom: MapConfig.maxZoom.toDouble(),
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
}
