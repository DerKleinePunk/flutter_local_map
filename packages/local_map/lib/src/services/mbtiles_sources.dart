import 'package:mbtiles/mbtiles.dart';
import 'package:path/path.dart' as p;
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_mbtiles/vector_map_tiles_mbtiles.dart';

// Oeffnet MBTiles, ohne dass das Paket mbtiles die Metadaten selbst liest.
//
// mbtiles 0.5.1 liest `version` mit double.parse. planetiler (und damit
// z. B. der Yapaia-Kartenserver) schreibt dort eine Versionsnummer wie
// `3.16.0` - die Karte brach dann beim Start ab. Die Metadaten liest
// local_map selbst und tolerant; gzip und die Zoomgrenzen werden deshalb
// hier mitgegeben, sonst holt mbtiles sie sich aus `getMetadata()`.

/// Vektorkacheln (`pbf`) sind gzip-gepackt.
MbTiles openVectorMbTiles(String path) => MbTiles(path: path, gzip: true);

/// Rasterkacheln (`png`, `jpg`, `webp`) sind nicht gepackt.
MbTiles openRasterMbTiles(String path) => MbTiles(path: path, gzip: false);

/// Vektorquelle mit den Zoomgrenzen aus unseren Metadaten. Ueber
/// [maxZoom] hinaus vergroessert vector_map_tiles die letzte Stufe.
MbTilesVectorTileProvider vectorTileProvider(
  MbTiles mbtiles, {
  double? minZoom,
  double? maxZoom,
}) {
  return MbTilesVectorTileProvider(
    mbtiles: mbtiles,
    minimumZoom: minZoom?.floor() ?? 0,
    maximumZoom: maxZoom?.floor() ?? 16,
  );
}

/// Pfad einer Zusatzquelle: relativ heisst neben der Hauptdatei.
String resolveExtraSourcePath(String mainPath, String file) =>
    p.isAbsolute(file) ? file : p.join(p.dirname(mainPath), file);

/// Ordnet jeder Quelle des Styles ihren Provider zu. Quellen mit eigener
/// Datei bekommen die, alle anderen die Hauptkarte - so wie bisher.
///
/// Ausnahme: eine Quelle aus [configuredExtras] (aus der Konfiguration oder
/// im Style mit `"local_map:extra": true` markiert), deren Datei fehlt, bekommt
/// keinen Provider. vector_map_tiles liefert dann leere Kacheln. An der
/// Hauptkarte haengend wuerde jede Kachel ein zweites Mal geladen und
/// dekodiert, weil der Renderer je Quelle zwischenspeichert - fuer Ebenen,
/// die dort ohnehin nichts finden.
Map<String, VectorTileProvider> assignVectorSourceProviders({
  required Iterable<String> sourceIds,
  required VectorTileProvider main,
  Map<String, VectorTileProvider> extras = const {},
  Iterable<String> configuredExtras = const [],
}) {
  final configured = configuredExtras.toSet();
  return {
    for (final id in sourceIds)
      if (extras[id] != null)
        id: extras[id]!
      else if (!configured.contains(id))
        id: main,
  };
}

/// Quellen, die der Style als Zusatzquelle markiert (`"local_map:extra": true`
/// in `sources`). Sie kommen nie aus der Hauptdatei, auch wenn der Gastgeber
/// keine Datei dafuer konfiguriert hat.
Set<String> extraOnlySourceIds(Map<String, dynamic> styleJson) {
  final sources = styleJson['sources'];
  if (sources is! Map) return const {};
  return {
    for (final entry in sources.entries)
      if (entry.key is String &&
          entry.value is Map &&
          (entry.value as Map)['local_map:extra'] == true)
        entry.key as String,
  };
}
