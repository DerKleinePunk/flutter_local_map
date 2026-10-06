import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api/position.dart';
import '../api/reverse_geocoder.dart';
import '../api/routing.dart';
import '../navigation/announcer.dart';
import '../navigation/heading_filter.dart';
import '../navigation/off_route.dart';
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
    this.reverseGeocoder,
    PositionSource? positionSource,
    MapController? mapController,
    this.offRoutePolicy = const OffRoutePolicy(),
    this.announcementPolicy = const AnnouncementPolicy(),
    DateTime Function()? clock,
  }) : mapController = mapController ?? MapController(),
       _ownsMapController = mapController == null,
       _clock = clock ?? DateTime.now {
    if (positionSource != null) {
      _positionSubscription = positionSource.positions.listen(_onPosition);
    }
  }

  /// Liefert die Routen. Ohne ihn bleibt die Karte ohne Routing.
  final RoutingProvider? routingProvider;

  /// Benennt die eigene Position für [locationName]. Ohne ihn bleibt
  /// [locationName] leer.
  final ReverseGeocoder? reverseGeocoder;

  /// Wann die Route als verlassen gilt und ob und wie oft dann neu berechnet
  /// wird.
  final OffRoutePolicy offRoutePolicy;

  /// Wann Abbiegeansagen kommen; `enabled: false` schaltet
  /// [announcements] stumm.
  final AnnouncementPolicy announcementPolicy;

  final DateTime Function() _clock;

  /// Erst nach so viel Bewegung wird die Position neu benannt. Ein
  /// GPS-Empfänger meldet sich bis zu zehnmal je Sekunde, eine Straße
  /// wechselt man seltener.
  static const double _locationNameMinMoveMeters = 25;

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
  LocationName? _locationName;
  LatLng? _locationNameAt;
  bool _locationNameLookupRunning = false;

  /// Ob die aktuelle Route aus [setStart]/[setDestination] kommt. Nur dann
  /// gibt es ein Ziel des Nutzers, zu dem neu berechnet werden kann.
  bool _routeHasDestination = false;
  bool _offRoute = false;
  bool _isRerouting = false;
  int _rerouteCount = 0;
  String? _rerouteError;
  String? _loggedRerouteError;
  int _rerouteFailures = 0;
  DateTime? _nextRerouteAt;
  final StreamController<bool> _offRouteChanges =
      StreamController<bool>.broadcast();
  ManeuverAnnouncer? _announcer;
  final StreamController<AnnouncementEvent> _announcements =
      StreamController<AnnouncementEvent>.broadcast();

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

  /// Ob die Route verlassen ist (siehe [OffRoutePolicy]). Wechsel kommen
  /// auch einzeln über [offRouteChanges].
  bool get offRoute => _offRoute;

  /// Meldet jeden Wechsel von [offRoute], `true` beim Verlassen, `false`
  /// zurück auf der Route oder mit einer neuen Route.
  Stream<bool> get offRouteChanges => _offRouteChanges.stream;

  /// Ob gerade wegen [offRoute] neu berechnet wird. Die alte Route bleibt
  /// so lange stehen.
  bool get isRerouting => _isRerouting;

  /// Wie oft die Route seit dem letzten [setStart]/[setDestination]/
  /// [setRoute] erfolgreich neu berechnet wurde.
  int get rerouteCount => _rerouteCount;

  /// Meldung der letzten gescheiterten Neuberechnung, `null` nach einem
  /// Erfolg. Die alte Route bleibt dann stehen.
  String? get rerouteError => _rerouteError;

  /// Abbiegeansagen zum Sprechen: [AnnouncementPrepare] mit den Sätzen, die
  /// bald kommen können, und [Announcement], wenn gesprochen werden soll.
  /// Die Karte spricht nicht selbst - das macht der Gastgeber.
  Stream<AnnouncementEvent> get announcements => _announcements.stream;

  /// Wo die eigene Position liegt - Straße, Ort, Ortsteil. Wird nur ohne
  /// [route] nachgeführt, denn während einer Zielführung zeigt die Karte das
  /// nächste Manöver; mit einer Route ist es `null`. Braucht einen
  /// [reverseGeocoder].
  LocationName? get locationName => _locationName;

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

  /// Setzt das Ziel und berechnet die Route neu. Ohne [start] beginnt die
  /// Route an der eigenen Position.
  Future<void> setDestination(GeocoderResult? place) {
    _destination = place;
    return _updateRoute();
  }

  /// Setzt eine fertige Route, ohne [routingProvider] zu fragen - etwa eine
  /// vom Backend berechnete oder eine per Map-Matching aus einer
  /// Aufzeichnung gewonnene. [start] und [destination] sind optional und nur
  /// für die Markierungen. `null` entfernt die Route.
  void setRoute(
    RoutingResult? route, {
    GeocoderResult? start,
    GeocoderResult? destination,
  }) {
    // Eine noch laufende Berechnung darf diese Route nicht überschreiben.
    _routeRequest++;
    _start = start;
    _destination = destination;
    _isRouting = false;
    _routingError = null;
    _setRoute(route, hasDestination: false);
    if (route != null) {
      _followPosition = false;
      _view?.fitRoute(_routePoints);
    }
    _notify();
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

    // Ohne Startpunkt geht es von der eigenen Position los. Kennt die Karte
    // noch keine, entscheidet der Anbieter (ein Backend hat seinen Fix).
    final origin = start?.location ?? _position?.position;

    if (destination == null || provider == null) {
      _setRoute(null, hasDestination: false);
      _isRouting = false;
      _notify();
      return;
    }

    _isRouting = true;
    _routingError = null;
    _notify();

    try {
      final result = await provider.route(
        start: origin,
        end: destination.location,
        // Nur wenn die Route an der eigenen Position beginnt.
        startHeadingDegrees: start == null ? _drivingHeading(_position) : null,
      );
      // Eine neuere Anfrage läuft schon - ihr Ergebnis gilt, nicht dieses.
      if (_disposed || request != _routeRequest) return;
      _setRoute(result, hasDestination: true);
      _routingAvailable = true;
      // Erst die Übersicht über die ganze Route; die Fahrt beginnt, wenn
      // der Gastgeber den Folgemodus wieder einschaltet.
      _followPosition = false;
      _view?.fitRoute(_routePoints);
    } catch (e) {
      if (_disposed || request != _routeRequest) return;
      _setRoute(null, hasDestination: false);
      _routingError = e is RoutingException ? e.message : e.toString();
    } finally {
      if (!_disposed && request == _routeRequest) {
        _isRouting = false;
        _notify();
      }
    }
  }

  /// [hasDestination]: die Route führt zu einem Ziel des Nutzers und darf
  /// neu berechnet werden. [rerouted]: sie ist selbst eine Neuberechnung,
  /// Zähler und Wartezeit laufen dann weiter.
  void _setRoute(
    RoutingResult? route, {
    required bool hasDestination,
    bool rerouted = false,
  }) {
    _route = route;
    _routeHasDestination = route != null && hasDestination;
    _routePoints = route == null
        ? const <LatLng>[]
        : route.geometry.map((p) => p.toLatLng()).toList(growable: false);
    _tracker = route == null
        ? null
        : RouteTracker(route, offRoutePolicy: offRoutePolicy);
    _announcer = route == null
        ? null
        : ManeuverAnnouncer(route, announcementPolicy);
    if (!rerouted) {
      _rerouteCount = 0;
      _rerouteFailures = 0;
      _rerouteError = null;
      _loggedRerouteError = null;
      _nextRerouteAt = null;
      _isRerouting = false;
    }
    final fix = _position;
    _progress = fix == null ? null : _trackFix(fix);
    _setOffRoute(_progress?.offRoute ?? false);
    _announce(fix);
    // Mit Route ruht die Anzeige; ohne soll die nächste Position sofort neu
    // benannt werden, nicht erst nach 25 m.
    _locationName = null;
    _locationNameAt = null;
    if (route == null && fix != null) {
      _updateLocationName(fix.position);
    }
  }

  void _onPosition(PositionFix fix) {
    if (_disposed) return;
    _position = fix;
    _headingFilter.update(fix);
    _progress = _trackFix(fix);
    _setOffRoute(_progress?.offRoute ?? false);
    _announce(fix);
    if (_route == null) {
      _updateLocationName(fix.position);
    }
    _maybeReroute(fix);
    _notify();
    _view?.positionChanged(fix);
  }

  RouteProgress? _trackFix(PositionFix fix) => _tracker?.update(
    fix.position,
    headingDegrees: fix.headingDegrees,
    speedMps: fix.speedMps,
    accuracyMeters: fix.accuracyMeters,
  );

  void _setOffRoute(bool value) {
    if (_offRoute == value) return;
    _offRoute = value;
    if (value) {
      debugPrint('[route] Route verlassen');
      // Nur ansagen, was dann auch passiert.
      final announcer = _announcer;
      if (announcer != null &&
          announcementPolicy.enabled &&
          offRoutePolicy.reroute &&
          _routeHasDestination) {
        _emit(announcer.rerouting());
      }
    }
    _offRouteChanges.add(value);
  }

  void _announce(PositionFix? fix) {
    final announcer = _announcer;
    final progress = _progress;
    if (announcer == null || progress == null || fix == null) return;
    for (final event in announcer.update(
      progress,
      speedMps: fix.speedMps,
      offRoute: _offRoute,
    )) {
      _emit(event);
    }
  }

  void _emit(AnnouncementEvent event) {
    if (event is Announcement) {
      debugPrint('[route] Ansage (${event.priority.name}): ${event.text}');
    }
    _announcements.add(event);
  }

  /// Berechnet neu, wenn die Route verlassen ist, sie ein Ziel hat, das
  /// Fahrzeug fährt und die Wartezeit um ist.
  void _maybeReroute(PositionFix fix) {
    if (!_offRoute ||
        !offRoutePolicy.reroute ||
        !_routeHasDestination ||
        _isRerouting ||
        _isRouting) {
      return;
    }
    final speed = fix.speedMps;
    if (speed != null && speed < offRoutePolicy.minSpeedMps) return;
    final now = _clock();
    final next = _nextRerouteAt;
    if (next != null && now.isBefore(next)) return;
    _reroute(fix);
  }

  /// Kurs für den Start einer Route an [fix], nur während der Fahrt - im
  /// Stand oder ohne bekannte Geschwindigkeit ist er nicht verlässlich. Der
  /// ungeglättete Kurs: Gleich nach dem Abbiegen hinkt der geglättete nach.
  double? _drivingHeading(PositionFix? fix) {
    final speed = fix?.speedMps;
    if (fix == null || speed == null || speed < _headingFilter.minSpeedMps) {
      return null;
    }
    return fix.headingDegrees;
  }

  Future<void> _reroute(PositionFix fix) async {
    final provider = routingProvider;
    final destination = _destination;
    if (provider == null || destination == null) return;
    final request = ++_routeRequest;
    _isRerouting = true;
    _notify();

    try {
      final result = await provider.route(
        start: fix.position,
        end: destination.location,
        startHeadingDegrees: _drivingHeading(fix),
      );
      if (_disposed || request != _routeRequest) return;
      _rerouteCount++;
      _rerouteFailures = 0;
      _rerouteError = null;
      _loggedRerouteError = null;
      _nextRerouteAt = _clock().add(_rerouteInterval());
      debugPrint(
        '[route] Route neu berechnet (#$_rerouteCount), '
        '${(result.distanceMeters / 1000).toStringAsFixed(1)} km',
      );
      // Kamera und Folgemodus bleiben: Der Fahrer ist unterwegs.
      _setRoute(result, hasDestination: true, rerouted: true);
    } catch (e) {
      if (_disposed || request != _routeRequest) return;
      final message = e is RoutingException ? e.message : e.toString();
      _rerouteError = message;
      _rerouteFailures++;
      _nextRerouteAt = _clock().add(_rerouteInterval());
      if (message != _loggedRerouteError) {
        _loggedRerouteError = message;
        debugPrint('[route] Neuberechnung fehlgeschlagen: $message');
      }
    } finally {
      if (!_disposed && request == _routeRequest) {
        _isRerouting = false;
        _notify();
      }
    }
  }

  /// Wartezeit bis zur nächsten Neuberechnung, nach Fehlschlägen länger.
  Duration _rerouteInterval() {
    final intervals = offRoutePolicy.rerouteIntervals;
    if (intervals.isEmpty) return Duration.zero;
    return intervals[math.min(_rerouteFailures, intervals.length - 1)];
  }

  Future<void> _updateLocationName(LatLng position) async {
    final geocoder = reverseGeocoder;
    if (geocoder == null || _locationNameLookupRunning) return;
    final last = _locationNameAt;
    if (last != null &&
        const Distance()(last, position) < _locationNameMinMoveMeters) {
      return;
    }
    _locationNameLookupRunning = true;
    try {
      final name = await geocoder.nameAt(position);
      // Inzwischen ist eine Route da - dann gilt die Anzeige nicht mehr.
      if (_disposed || _route != null) return;
      _locationNameAt = position;
      if (name != _locationName) {
        _locationName = name;
        _notify();
      }
    } catch (_) {
      // Die Anzeige ist ein Zusatz. Schlägt sie fehl, bleibt die alte stehen,
      // und die nächste Position versucht es erneut.
    } finally {
      _locationNameLookupRunning = false;
    }
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
    _offRouteChanges.close();
    _announcements.close();
    _zoom.dispose();
    if (_ownsMapController) {
      mapController.dispose();
    }
    super.dispose();
  }
}
