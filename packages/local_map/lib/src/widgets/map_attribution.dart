import 'package:flutter/material.dart';

import '../config/map_config.dart';

/// Quellenangabe der Kartendaten, immer ausgeschrieben.
///
/// OpenStreetMap verlangt den Hinweis sichtbar auf der Karte, ohne dass man
/// erst etwas antippen muss. Der `RichAttributionWidget` von flutter_map
/// zeigt nur ein (i) und den Text erst nach einem Tipp; das reicht nicht.
///
/// Als Kind einer `FlutterMap` (oder eines `Stack`) legt sich der Hinweis in
/// die Ecke [alignment], mit [padding] Abstand zum Rand. Der Gastgeber wählt
/// Ecke und Abstand so, dass keine eigenen Bedienelemente darüber liegen.
class MapAttribution extends StatelessWidget {
  const MapAttribution({
    super.key,
    this.text = MapConfig.osmAttribution,
    this.alignment = Alignment.bottomRight,
    this.padding = const EdgeInsets.all(4),
  });

  /// Text, Ecke und Abstand aus [config].
  MapAttribution.fromConfig(MapConfig config, {Key? key})
    : this(
        key: key,
        text: config.attributionText,
        alignment: config.attributionAlignment,
        padding: config.attributionPadding,
      );

  final String text;
  final Alignment alignment;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: padding,
        // Halbdurchsichtig hinterlegt: auf heller und dunkler Karte lesbar.
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xB3000000),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xFFFFFFFF),
                fontSize: 11,
                height: 1.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
