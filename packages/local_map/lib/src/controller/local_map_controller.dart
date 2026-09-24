import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api/position.dart';
import '../api/routing.dart';
import '../navigation/heading_filter.dart';
import '../navigation/route_progress.dart';
import '../services/offline_geocoder.dart';

/// Was eine eingehängte [MapView] für den Controller erledigt.
///
/// Kamerabefehle brauchen die Zoomgrenzen der geladenen Kacheln und die
/// Konfiguration - beides kennt nur die Ansicht.
abstract interface class LocalMapViewHandle {
  void moveToPlace(GeocoderResult place);
  void fitRoute(List<LatLng> points);
  void stepZoom(int direction);
  Future<void> cycleVectorStyle();

  /// Eine neue Position ist da, oder Folgemodus bzw. Ausrichtung haben sich
  /// geändert. Die Ansicht bewegt den Pfeil und - wenn [followPosition] an
  /// ist - die Kamera, gedreht nach [heading], falls [headingUp] an ist.
  void positionChanged(PositionFix fix);

  /// Dreht die Karte zurück auf Norden oben.
  void resetRotation();
}

/// Zustand und Befehle der Karte, für die Bedienung durch den Gastgeber.
///
/// [MapView] zeichnet, was hier steht: Route, Start und Ziel, den
/// hervorgehobenen Ort und die eigene Position. Suchfelder, Knöpfe und
/// Anzeigen baut der Gastgeber selbst und spricht dafür nur diesen
/// Controller an. Änderungen meldet er als [ChangeNotifier]; der Zoom
/// kommt getrennt über [zoom], weil er sich bei jeder Geste ändert.
class LocalMapController extends ChangeNotifier {
  LocalMapController({
    this.routingProvider,
    PositionSource? positionSource,
    MapController? mapController,
  }) : mapController = mapController ?? MapController(),
       _ownsMapController = mapController == null {
    if (positionSource != null) {
      _positionSubscription = positionSource.positions.listen(_onPosition);
    }
  }

  /// Liefert die Routen. Ohne ihn bleibt die Karte ohne Routing.
  final RoutingProvider? routingProvider;

  /// Die Kamera von flutter_map, für alles, was dieser Controller nicht
  /// selbst anbietet.
  final MapController mapController;
  final bool _ownsMapController;

  StreamSubscription<PositionFix>? _positionSubscription;
  LocalMapViewHandle? _view;
  int _routeRequest = 0;
  bool _disposed = false;

  GeocoderResult? _start;
  GeocoderResult? _destination;
  GeocoderResult? _highlightedPlace;
  RoutingResult? _route;
  List<LatLng> _routePoints = const <LatLng>[];
  bool _isRouting = false;
  String? _routingError;
  bool? _routingAvailable;
  PositionFix? _position;
  bool _followPosition = true;
  bool _headingUp = false;
  final HeadingFilter _headingFilter = HeadingFilter();
  RouteTracker? _tracker;
  RouteProgress? _progress;
  bool _isVectorMode = false;
  String? _activeStyleName;
  double _minZoom = 0;
  double _maxZoom = 22;

  final ValueNotifier<double> _zoom = ValueNotifier<double>(0);

  GeocoderResult? get start => _start;
  GeocoderResult? get destination => _destination;

  /// Der zuletzt gesuchte Ort, als Markierung auf der Karte.
  GeocoderResult? get highlightedPlace => _highlightedPlace;

  /// Die aktuelle Route, `null` solange Start oder Ziel fehlen.
  RoutingResult? get route => _route;

  /// Die Geometrie von [route] als Punkte für die Karte.
  List<LatLng> get routePoints => _routePoints;

  bool get isRouting => _isRouting;

  /// Meldung der letzten gescheiterten Routenberechnung.
  String? get routingError => _routingError;

  /// Ergebnis von [checkRoutingAvailability]; `null` = noch nicht geprüft.
  bool? get routingAvailable => _routingAvailable;

  /// Die letzte Meldung der Positionsquelle.
  PositionFix? get position => _position;

  /// Ob die Kamera der Position folgt.
  bool get followPosition => _followPosition;
  set followPosition(bool value) {
    if (_followPosition == value) return;
    _followPosition = value;
    _notify();
    _refollow();
  }

  /// Ob die Karte in Fahrtrichtung gedreht wird, solange sie der Position
  /// folgt. Aus: Norden oben.
  bool get headingUp => _headingUp;
  set headingUp(bool value) {
    if (_headingUp == value) return;
    _headingUp = value;
    _notify();
    if (!value) {
      _view?.resetRotation();
    }
    _refollow();
  }

  /// Der Kurs, nach dem die Karte gedreht wird: der GPS-Kurs, geglättet und
  /// im Stand eingefroren. `null`, solange keiner bekannt ist.
  double? get heading => _headingFilter.heading;

  /// Stand der Position auf der Route: nächstes Manöver, Restweg, Abstand.
  /// `null` ohne Route oder ohne Position.
  RouteProgress? get progress => _progress;

  /// Aktueller Zoom der Kamera.
  ValueListenable<double> get zoom => _zoom;
  double get minZoom => _minZoom;
  double get maxZoom => _maxZoom;

  /// Ob Vektorkacheln geladen sind (sonst Raster).
  bool get isVectorMode => _isVectorMode;

  /// Name des aktiven Vektorstyles, `null` im Raster- oder Fallback-Fall.
  String? get activeStyleName => _activeStyleName;

  /// Setzt den Startpunkt und berechnet die Route neu.
  Future<void> setStart(GeocoderResult? place) {
    _start = place;
    return _updateRoute();
  }

  /// Setzt das Ziel und berechnet die Route neu.
  Future<void> setDestination(GeocoderResult? place) {
    _destination = place;
    return _updateRoute();
  }

  /// Hebt [place] hervor und bewegt die Kamera dorthin. Der Folgemodus
  /// endet dabei, sonst holte die nächste Positionsmeldung die Kamera
  /// sofort zurück.
  void showPlace(GeocoderResult place) {
    _highlightedPlace = place;
    _followPosition = false;
    _notify();
    _view?.moveToPlace(place);
  }

  void clearHighlight() {
    if (_highlightedPlace == null) return;
    _highlightedPlace = null;
    _notify();
  }

  void zoomIn() => _view?.stepZoom(1);
  void zoomOut() => _view?.stepZoom(-1);

  /// Wechselt zum nächsten Vektorstyle aus der Konfiguration.
  Future<void> cycleVectorStyle() async => _view?.cycleVectorStyle();

  /// Fragt [routingProvider], ob er Anfragen annimmt.
  Future<bool> checkRoutingAvailability() async {
    final provider = routingProvider;
    final available = provider != null && await provider.isAvailable();
    if (_disposed) return available;
    _routingAvailable = available;
    _notify();
    return available;
  }

  Future<void> _updateRoute() async {
    final request = ++_routeRequest;
    final start = _start;
    final destination = _destination;
    final provider = routingProvider;

    if (start == null || destination == null || provider == null) {
      _setRoute(null);
      _isRouting = false;
      _notify();
      return;
    }

    _isRouting = true;
    _routingError = null;
    _notify();

    try {
      final result = await provider.route(
        start: start.location,
        end: destination.location,
      );
      // Eine neuere Anfrage läuft schon - ihr Ergebnis gilt, nicht dieses.
      if (_disposed || request != _routeRequest) return;
      _setRoute(result);
      _routingAvailable = true;
      // Erst die Übersicht über die ganze Route; die Fahrt beginnt, wenn
      // der Gastgeber den Folgemodus wieder einschaltet.
      _followPosition = false;
      _view?.fitRoute(_routePoints);
    } catch (e) {
      if (_disposed || request != _routeRequest) return;
      _setRoute(null);
      _routingError = e is RoutingException ? e.message : e.toString();
    } finally {
      if (!_disposed && request == _routeRequest) {
        _isRouting = false;
        _notify();
      }
    }
  }

  void _setRoute(RoutingResult? route) {
    _route = route;
    _routePoints = route == null
        ? const <LatLng>[]
        : route.geometry.map((p) => p.toLatLng()).toList(growable: false);
    _tracker = route == null ? null : RouteTracker(route);
    final fix = _position;
    _progress = fix == null ? null : _tracker?.update(fix.position);
  }

  void _onPosition(PositionFix fix) {
    if (_disposed) return;
    _position = fix;
    _headingFilter.update(fix);
    _progress = _tracker?.update(fix.position);
    _notify();
    _view?.positionChanged(fix);
  }

  void _refollow() {
    final fix = _position;
    if (_followPosition && fix != null) {
      _view?.positionChanged(fix);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // --- nur für MapView -----------------------------------------------------

  /// Hängt eine Ansicht ein. Nur für [MapView].
  void attachView(LocalMapViewHandle view) => _view = view;

  /// Hängt die Ansicht wieder aus. Nur für [MapView].
  void detachView(LocalMapViewHandle view) {
    if (identical(_view, view)) _view = null;
  }

  /// Meldet den Zustand der geladenen Kacheln. Nur für [MapView].
  void reportMapState({
    required bool isVectorMode,
    required String? activeStyleName,
    required double minZoom,
    required double maxZoom,
  }) {
    if (_isVectorMode == isVectorMode &&
        _activeStyleName == activeStyleName &&
        _minZoom == minZoom &&
        _maxZoom == maxZoom) {
      return;
    }
    _isVectorMode = isVectorMode;
    _activeStyleName = activeStyleName;
    _minZoom = minZoom;
    _maxZoom = maxZoom;
    _notify();
  }

  /// Meldet den Zoom der Kamera. Nur für [MapView].
  void reportZoom(double zoom) => _zoom.value = zoom;

  @override
  void dispose() {
    _disposed = true;
    _positionSubscription?.cancel();
    _zoom.dispose();
    if (_ownsMapController) {
      mapController.dispose();
    }
    super.dispose();
  }
}
