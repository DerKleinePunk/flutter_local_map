/// Offline-Kartendarstellung auf Basis von MBTiles.
///
/// Einstiegspunkte:
/// * [LocalMap.ensureInitialized] einmalig in `main()` aufrufen.
/// * [MapConfig] konfiguriert Zoom, Mittelpunkt, Styles und Endpunkte.
/// * [MapView] rendert die Karte, [LocalMapController] steuert sie.
/// * [DownloadOverlay] zeigt den Erst-Download.
library;

// Schnittstellen, ueber die der Gastgeber Routing, Position und Suche
// selbst liefern kann.
export 'src/api/place_search.dart';
export 'src/api/reverse_geocoder.dart';
export 'src/api/position.dart';
export 'src/api/routing.dart';

export 'src/config/map_config.dart';
export 'src/controller/local_map_controller.dart';
export 'src/navigation/heading_filter.dart';
export 'src/navigation/route_progress.dart';
export 'src/services/gps_nmea_simulator_service.dart';
export 'src/services/map_downloader.dart';
export 'src/services/map_error_handler.dart';
export 'src/services/offline_geocoder.dart';
export 'src/services/valhalla_routing_service.dart';
export 'src/widgets/download_overlay.dart';
export 'src/widgets/map_view.dart';
export 'src/widgets/search_bar.dart';
export 'src/widgets/storage_settings_dialog.dart';

// Typen, die in der oeffentlichen API dieses Packages auftauchen und die
// konsumierende Projekte sonst separat importieren muessten.
export 'package:latlong2/latlong.dart' show LatLng;
export 'package:flutter_map/flutter_map.dart' show LatLngBounds, MapController;

export 'src/local_map_init.dart';
