import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Die Styles muessen zu den Klassen passen, die in den Kacheln stehen.
///
/// Gemessen an einem Hessen-Ausschnitt aus `germany-vec.mbtiles` (200 grosse
/// z16-Kacheln, 42.474 Strassenobjekte) fuehrt die Ebene `transportation`
/// diese Werte unter `class`:
///
///   path 56,2 % | service 16,2 % | minor 13,4 % | primary 3,5 %
///   secondary 3,5 % | tertiary 2,4 % | transit 2,2 % | rail 1,8 % | ...
///
/// Die Klassen `residential` und `unclassified` kommen **nicht** vor -
/// Wohnstrassen laufen unter `minor`. Ein Style, der nur auf `residential`
/// filtert, zeichnet in Wohngebieten gar keine Strassen, waehrend die
/// Hausnummern erscheinen. Genau das war auf dem Pi zu sehen.
const _wohnstrassenKlasse = 'minor';

List<Map<String, dynamic>> _layers(String assetPath) {
  final raw = File(assetPath).readAsStringSync();
  final style = jsonDecode(raw) as Map<String, dynamic>;
  return (style['layers'] as List).cast<Map<String, dynamic>>();
}

/// Sammelt alle Klassen, die ein Style aus `transportation` zeichnet.
/// `null` bedeutet: die Ebene hat keinen Filter, zeichnet also alles.
Set<String>? _gezeichneteKlassen(List<Map<String, dynamic>> layers) {
  final klassen = <String>{};
  for (final layer in layers) {
    if (layer['source-layer'] != 'transportation') continue;
    final filter = layer['filter'];
    if (filter == null) return null;
    final list = (filter as List).cast<dynamic>();
    if (list.length >= 2 && list[0] == 'in' && list[1] == 'class') {
      klassen.addAll(list.skip(2).map((e) => e.toString()));
    }
  }
  return klassen;
}

void main() {
  final styles = Directory('assets/maps')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList();

  test('es gibt Styles zu pruefen', () {
    expect(styles, isNotEmpty);
  });

  test('jeder Style hat eine eigene id', () {
    // vector_map_tiles entscheidet allein an `theme.id` und `theme.version`,
    // ob es nach einem Stilwechsel neu zeichnet - siehe
    // VectorTileLayerOptions.hasRenderDifferences und
    // _VectorTileLayerState.didUpdateWidget. ThemeReader setzt
    // `json['id'] ?? 'default'`. Ohne eigene id tragen alle Styles dieselbe,
    // der Umschalter wirkt korrekt, und das Bild aendert sich trotzdem nie.
    final ids = <String, String>{};
    for (final style in styles) {
      final json =
          jsonDecode(style.readAsStringSync()) as Map<String, dynamic>;
      final id = json['id'];
      final name = style.uri.pathSegments.last;

      expect(
        id,
        isA<String>().having((s) => s.isNotEmpty, 'nicht leer', isTrue),
        reason: '$name braucht ein id-Feld',
      );
      expect(
        ids,
        isNot(contains(id)),
        reason: '$name teilt sich die id "$id" mit ${ids[id]}',
      );
      ids[id as String] = name;
    }
  });

  for (final style in styles) {
    final name = style.uri.pathSegments.last;

    test('$name zeichnet Wohnstrassen', () {
      final layers = _layers(style.path);
      final klassen = _gezeichneteKlassen(layers);

      if (klassen == null) {
        // Kein Filter: der Style zeichnet alle Strassen.
        return;
      }

      expect(
        klassen,
        contains(_wohnstrassenKlasse),
        reason:
            'Die Kacheln fuehren Wohnstrassen unter class="$_wohnstrassenKlasse". '
            'Ohne diese Klasse bleiben Wohngebiete ohne Strassen.',
      );
    });

    test('$name zeigt keine Hausnummern ohne Strassen', () {
      final layers = _layers(style.path);
      final hausnummern = layers.where(
        (l) => l['source-layer'] == 'housenumber',
      );
      if (hausnummern.isEmpty) return;

      final klassen = _gezeichneteKlassen(layers);
      expect(
        klassen == null || klassen.contains(_wohnstrassenKlasse),
        isTrue,
        reason:
            'Der Style beschriftet Haeuser, zeichnet aber die Strassen nicht, '
            'an denen sie liegen.',
      );
    });
  }
}
