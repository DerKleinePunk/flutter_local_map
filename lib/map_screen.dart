import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:local_map/local_map.dart';

/// Die Karte mit der Bedienung dieser Demo-App.
///
/// Hier entsteht, was ein Gastgeber der Karte selbst mitbringt: Suche,
/// Routing, Positionsquelle und die Knöpfe darüber. Die Karte selbst
/// ([MapView]) kennt davon nur den [LocalMapController].
class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.mbtilesPath,
    required this.config,
    this.mapController,
  });

  final String? mbtilesPath;
  final MapConfig config;

  /// Nur für den Messlauf, der die Kamera von außen fährt.
  final MapController? mapController;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final OfflineGeocoder _geocoder = OfflineGeocoder();
  final GpsNmeaSimulatorService _gpsSimulator = GpsNmeaSimulatorService();
  late final ValhallaRoutingService _routing;
  late final LocalMapController _map;

  bool _geocoderReady = false;
  int _gpsLoadedFixes = 0;
  String? _gpsSimMessage;

  @override
  void initState() {
    super.initState();
    _routing = ValhallaRoutingService(baseUri: widget.config.valhallaBaseUri);
    _map = LocalMapController(
      routingProvider: _routing,
      positionSource: _gpsSimulator,
      mapController: widget.mapController,
    );
    _map.checkRoutingAvailability();
    _initializeGeocoder();
  }

  @override
  void dispose() {
    _map.dispose();
    _gpsSimulator.dispose();
    _geocoder.close();
    super.dispose();
  }

  /// Die Namensdatenbank liegt neben den Kacheln:
  /// `germany.mbtiles` -> `germany_names.db`.
  Future<void> _initializeGeocoder() async {
    final namesDbPath = widget.mbtilesPath?.replaceAll('.mbtiles', '_names.db');
    if (namesDbPath == null || !File(namesDbPath).existsSync()) {
      MapErrorHandler.logInfo(
        'Keine Namensdatenbank, Suche aus',
        context: '$namesDbPath',
      );
      return;
    }
    final ok = await _geocoder.initialize(namesDbPath);
    if (mounted) {
      setState(() => _geocoderReady = ok);
    }
  }

  Future<void> _toggleGpsSimulation() async {
    if (_gpsSimulator.isRunning) {
      _gpsSimulator.stop();
      setState(() {});
      return;
    }

    try {
      if (!_gpsSimulator.hasData) {
        _gpsLoadedFixes = await _gpsSimulator.loadDefaultTourFile(
          candidatePaths: widget.config.gpsTourFilePaths,
        );
      }
      _gpsSimulator.start(loop: true);
      _gpsSimMessage = null;
    } catch (e) {
      _gpsSimMessage = e.toString();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      // expand, damit die Karte die volle Flaeche bekommt: ein Stack misst
      // sich sonst an seinem nicht positionierten Kind, und FlutterMap wuerde
      // unter losen Vorgaben nicht mehr fuellen.
      fit: StackFit.expand,
      children: [
        MapView(
          mbtilesPath: widget.mbtilesPath,
          config: widget.config,
          controller: _map,
        ),
        // Bedienelemente liegen bewusst ueber der Karte und nicht in ihr.
        // Als Kartenebenen konkurrierte ein Tipp mit der Gestenerkennung der
        // Karte: auf einem Touchscreen wackelt der Finger immer ein paar
        // Pixel, die Skaliergeste gewinnt, und der Knopf bekommt nichts ab.
        ListenableBuilder(
          listenable: _map,
          builder: (context, _) =>
              Stack(fit: StackFit.expand, children: _buildControls(context)),
        ),
      ],
    );
  }

  List<Widget> _buildControls(BuildContext context) {
    return [
      if (_geocoderReady)
        Positioned(
          top: 12,
          left: 200,
          right: 200,
          child: Column(
            children: [
              PlaceSearchBar(
                mapController: _map.mapController,
                geocoder: _geocoder,
                hintText: 'Start suchen...',
                prefixIcon: Icons.trip_origin,
                moveToResult: (_, result) => _map.showPlace(result),
                onClearSearch: () => _map.setStart(null),
                onPlaceSelected: _map.setStart,
              ),
              PlaceSearchBar(
                mapController: _map.mapController,
                geocoder: _geocoder,
                hintText: 'Ziel suchen...',
                prefixIcon: Icons.flag,
                moveToResult: (_, result) => _map.showPlace(result),
                onClearSearch: () => _map.setDestination(null),
                onPlaceSelected: _map.setDestination,
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
        child: IgnorePointer(child: _ZoomBadge(zoom: _map.zoom)),
      ),
      Positioned(
        top: 12,
        right: 12,
        child: IgnorePointer(
          child: _Badge(
            icon: _map.isVectorMode ? Icons.layers : Icons.grid_on,
            label: _map.isVectorMode
                ? 'Vektor MBTiles (PBF)'
                : 'Raster MBTiles',
            tone: _map.isVectorMode ? _Tone.tertiary : _Tone.primary,
          ),
        ),
      ),
      if (_map.isVectorMode)
        Positioned(
          top: 48,
          right: 12,
          child: _Badge(
            icon: Icons.palette_outlined,
            label: _map.activeStyleName ?? 'Fallback',
            tone: _Tone.secondary,
            onTap: _map.cycleVectorStyle,
          ),
        ),
      Positioned(top: 84, right: 12, child: _buildGpsSimulatorChip(context)),
      Positioned(
        bottom: 16,
        right: 12,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildNavigationButtons(context),
            const SizedBox(height: 12),
            _buildZoomButtons(context),
          ],
        ),
      ),
      if (_map.progress?.nextManeuver != null)
        Positioned(
          bottom: 16,
          left: 200,
          right: 200,
          child: _ManeuverCard(progress: _map.progress!),
        ),
    ];
  }

  /// Folgen und Ausrichtung - die beiden Schalter des Navigationsmodus.
  Widget _buildNavigationButtons(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomButton(
            icon: _map.followPosition
                ? Icons.my_location
                : Icons.location_searching,
            tooltip: _map.followPosition ? 'Folgt der Position' : 'Folgen',
            onPressed: _map.position == null
                ? null
                : () => _map.followPosition = !_map.followPosition,
          ),
          Divider(height: 1, thickness: 1, color: colorScheme.outlineVariant),
          _ZoomButton(
            icon: _map.headingUp ? Icons.navigation : Icons.explore,
            tooltip: _map.headingUp ? 'Fahrtrichtung oben' : 'Norden oben',
            onPressed: () => _map.headingUp = !_map.headingUp,
          ),
        ],
      ),
    );
  }

  Widget _buildRoutingBadge(BuildContext context) {
    final route = _map.route;
    if (_map.isRouting) {
      return const _Badge(
        icon: Icons.sync,
        label: 'Route wird berechnet...',
        tone: _Tone.tertiary,
      );
    }
    if (route != null) {
      final km = route.distanceMeters / 1000;
      final min = (route.durationSeconds / 60).round();
      return _Badge(
        icon: Icons.route,
        label: '${km.toStringAsFixed(1)} km • $min min',
        tone: _Tone.primary,
      );
    }
    final error = _map.routingError;
    if (error != null) {
      return _Badge(
        icon: Icons.warning_amber_rounded,
        label: error,
        tone: _Tone.error,
      );
    }
    return switch (_map.routingAvailable) {
      true => const _Badge(
        icon: Icons.route,
        label: 'Routing bereit',
        tone: _Tone.secondary,
      ),
      false => _Badge(
        icon: Icons.cloud_off,
        label: 'Valhalla nicht erreichbar (${_routing.baseUri.authority})',
        tone: _Tone.error,
      ),
      null => const SizedBox.shrink(),
    };
  }

  Widget _buildGpsSimulatorChip(BuildContext context) {
    final isRunning = _gpsSimulator.isRunning;
    final label = _gpsLoadedFixes > 0
        ? 'GPS Sim ${isRunning ? 'an' : 'aus'} ($_gpsLoadedFixes)'
        : (_gpsSimMessage ?? 'GPS Sim laden');
    return _Badge(
      icon: isRunning ? Icons.stop_circle_outlined : Icons.play_circle,
      label: label,
      tone: isRunning ? _Tone.primary : _Tone.secondary,
      onTap: _toggleGpsSimulation,
      trailing: GestureDetector(
        onTap: () => _map.followPosition = !_map.followPosition,
        child: Icon(
          _map.followPosition ? Icons.my_location : Icons.location_disabled,
          size: 14,
        ),
      ),
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
      valueListenable: _map.zoom,
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
                onPressed: zoom < _map.maxZoom ? _map.zoomIn : null,
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: colorScheme.outlineVariant,
              ),
              _ZoomButton(
                icon: Icons.remove,
                tooltip: 'Herauszoomen',
                onPressed: zoom > _map.minZoom ? _map.zoomOut : null,
              ),
            ],
          ),
        );
      },
    );
  }
}

enum _Tone { primary, secondary, tertiary, error }

/// Kleine Pille mit Symbol und Text, wahlweise antippbar.
class _Badge extends StatelessWidget {
  const _Badge({
    required this.icon,
    required this.label,
    required this.tone,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final _Tone tone;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (tone) {
      _Tone.primary => (
        colorScheme.primaryContainer,
        colorScheme.onPrimaryContainer,
      ),
      _Tone.secondary => (
        colorScheme.secondaryContainer,
        colorScheme.onSecondaryContainer,
      ),
      _Tone.tertiary => (
        colorScheme.tertiaryContainer,
        colorScheme.onTertiaryContainer,
      ),
      _Tone.error => (colorScheme.errorContainer, colorScheme.onErrorContainer),
    };

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: IconTheme.merge(
        data: IconThemeData(color: fg),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ],
        ),
      ),
    );

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? content : InkWell(onTap: onTap, child: content),
    );
  }
}

class _ZoomBadge extends StatelessWidget {
  const _ZoomBadge({required this.zoom});

  final ValueListenable<double> zoom;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<double>(
      valueListenable: zoom,
      builder: (context, value, _) => DecoratedBox(
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
                'Zoom ${value.toStringAsFixed(1)}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Nächstes Manöver mit Entfernung, darunter Restweg und Restzeit.
class _ManeuverCard extends StatelessWidget {
  const _ManeuverCard({required this.progress});

  final RouteProgress progress;

  static String _distance(double meters) => meters < 1000
      ? '${(meters / 10).round() * 10} m'
      : '${(meters / 1000).toStringAsFixed(1)} km';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final maneuver = progress.nextManeuver!;
    final toNext = progress.distanceToNextManeuverMeters ?? 0;
    final minutes = (progress.remainingSeconds / 60).round();

    return Material(
      color: colorScheme.surface.withValues(alpha: 0.95),
      elevation: 4,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Text(
              _distance(toNext),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    maneuver.instruction,
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'noch ${_distance(progress.remainingMeters)} • $minutes min',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

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
