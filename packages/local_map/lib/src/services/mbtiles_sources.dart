import 'package:mbtiles/mbtiles.dart';
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
