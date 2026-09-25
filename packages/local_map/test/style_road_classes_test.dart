import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

/// Der Klassenfilter allein genuegt nicht - die Strasse muss auch zu sehen
/// sein. Im Navigations-Style waren die Wohnstrassen `#ffffff` auf dem
/// Hintergrund `#f6f4ef`, also ein Kontrast von 1,10 : 1. Gezeichnet wurden
/// sie, sichtbar waren sie nicht, und das Bild sah wieder aus wie
/// "Hausnummern ohne Strassen".
///
/// 2,0 : 1 ist bewusst niedrig gewaehlt - es geht nicht um Lesbarkeit von
/// Text, sondern darum, eine unsichtbare Linie von einer sichtbaren zu
/// unterscheiden. Die Styles liegen mit 2,2 bis 5,2 darueber.
const _mindestKontrast = 2.0;

/// Relative Luminanz nach WCAG 2.1.
double _luminanz(String hexfarbe) {
  final hex = hexfarbe.replaceFirst('#', '');
  final kanaele = <double>[
    for (var i = 0; i < 6; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16) / 255,
  ];
  final linear = kanaele
      .map(
        (v) => v <= 0.03928
            ? v / 12.92
            : math.pow((v + 0.055) / 1.055, 2.4).toDouble(),
      )
      .toList();
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

double _kontrast(String a, String b) {
  final la = _luminanz(a);
  final lb = _luminanz(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

String? _hintergrundfarbe(List<Map<String, dynamic>> layers) {
  for (final layer in layers) {
    if (layer['type'] == 'background') {
      final paint = layer['paint'] as Map<String, dynamic>?;
      return paint?['background-color'] as String?;
    }
  }
  return null;
}

/// Die Klassen, die eine einzelne Ebene zeichnet. `null` heisst: alle.
Set<String>? _klassenDerEbene(Map<String, dynamic> layer) {
  final filter = layer['filter'];
  if (filter == null) return null;
  final list = (filter as List).cast<dynamic>();
  if (list.length >= 2 && list[0] == 'in' && list[1] == 'class') {
    return list.skip(2).map((e) => e.toString()).toSet();
  }
  return null;
}

/// Der beste Kontrast, mit dem eine Strassenklasse gezeichnet wird.
///
/// Eine helle Fuellung mit dunklem Casing gilt als sichtbar: es zaehlt die
/// kontraststaerkste Ebene, die diese Klasse zeichnet.
Map<String, double> _kontrastJeKlasse(
  List<Map<String, dynamic>> layers,
  String hintergrund,
) {
  final ergebnis = <String, double>{};
  final alleKlassen = <String>{};
  for (final layer in layers) {
    if (layer['source-layer'] != 'transportation') continue;
    alleKlassen.addAll(_klassenDerEbene(layer) ?? const <String>{});
  }

  for (final layer in layers) {
    if (layer['source-layer'] != 'transportation') continue;
    final paint = layer['paint'] as Map<String, dynamic>?;
    final farbe = paint?['line-color'] as String?;
    if (farbe == null) continue;

    final kontrast = _kontrast(farbe, hintergrund);
    final klassen = _klassenDerEbene(layer) ?? alleKlassen;
    final ziele = klassen.isEmpty ? {'*'} : klassen;
    for (final klasse in ziele) {
      final bisher = ergebnis[klasse];
      if (bisher == null || kontrast > bisher) {
        ergebnis[klasse] = kontrast;
      }
    }
  }
  return ergebnis;
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
      final json = jsonDecode(style.readAsStringSync()) as Map<String, dynamic>;
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

    test('$name zeichnet Strassen sichtbar', () {
      final layers = _layers(style.path);
      final hintergrund = _hintergrundfarbe(layers);
      expect(
        hintergrund,
        isNotNull,
        reason: '$name hat keine Hintergrundfarbe, der Kontrast ist unpruefbar',
      );

      final kontraste = _kontrastJeKlasse(layers, hintergrund!);
      if (kontraste.isEmpty) return;

      for (final eintrag in kontraste.entries) {
        expect(
          eintrag.value,
          greaterThanOrEqualTo(_mindestKontrast),
          reason:
              'class="${eintrag.key}" wird nur mit Kontrast '
              '${eintrag.value.toStringAsFixed(2)} : 1 gegen $hintergrund '
              'gezeichnet. Die Strasse ist damit praktisch unsichtbar - eine '
              'helle Linie braucht ein dunkleres Casing darunter.',
        );
      }
    });
  }
}
