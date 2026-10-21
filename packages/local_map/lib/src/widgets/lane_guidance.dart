import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/routing.dart';

/// Die Spuren vor einem Manöver als Pfeile, wie auf einem Wegweiser über der
/// Autobahn: richtige Spuren hell, die übrigen gedämpft.
///
/// Hell sind die [RoutingLane.active] Spuren. Gibt es keine, die gültigen
/// ([RoutingLane.valid]). Eine nur gültige Spur neben einer aktiven bleibt
/// gedämpft: von dort müsste man kurz vor der Ausfahrt noch einmal wechseln.
///
/// Ohne Spuren nimmt das Widget keinen Platz ein. Der Gastgeber entscheidet,
/// wann es zu sehen ist (etwa erst in den letzten 2 km vor dem Manöver).
class LaneGuidance extends StatelessWidget {
  const LaneGuidance({
    super.key,
    required this.lanes,
    this.laneWidth = 40,
    this.height = 44,
    this.validColor,
    this.invalidColor,
    this.backgroundColor,
  });

  /// Die Spuren von links nach rechts ([RoutingManeuver.lanes]).
  final List<RoutingLane> lanes;

  final double laneWidth;
  final double height;

  /// Farbe der richtigen Spuren. Vorgabe: `onPrimary` des Themas.
  final Color? validColor;

  /// Farbe der übrigen Spuren. Vorgabe: [validColor] mit 35 % Deckung.
  final Color? invalidColor;

  /// Hintergrund der Leiste. Vorgabe: `primary` des Themas.
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    if (lanes.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final on = validColor ?? scheme.onPrimary;
    final off = invalidColor ?? on.withValues(alpha: 0.35);
    final anyActive = lanes.any((l) => l.active);
    bool lit(RoutingLane l) => anyActive ? l.active : l.valid;
    final valid = lanes.where(lit).length;
    return Semantics(
      label: 'Spuren: $valid von ${lanes.length} richtig',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: backgroundColor ?? scheme.primary,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < lanes.length; i++) ...[
                if (i > 0)
                  SizedBox(
                    height: height * 0.6,
                    child: VerticalDivider(width: 2, thickness: 2, color: off),
                  ),
                SizedBox(
                  key: ValueKey('lane-$i'),
                  width: laneWidth,
                  height: height,
                  child: CustomPaint(
                    painter: LaneArrowPainter(
                      lane: lanes[i],
                      highlighted: lit(lanes[i]),
                      validColor: on,
                      invalidColor: off,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Malt die Pfeile einer Spur. Der Pfeil, dem die Route folgt, kommt in
/// [validColor], alle anderen in [invalidColor].
class LaneArrowPainter extends CustomPainter {
  LaneArrowPainter({
    required this.lane,
    bool? highlighted,
    required this.validColor,
    required this.invalidColor,
  }) : highlighted = highlighted ?? lane.valid;

  final RoutingLane lane;

  /// Ob die Spur hell erscheint. Vorgabe: [RoutingLane.valid];
  /// [LaneGuidance] setzt es nach seiner Regel.
  final bool highlighted;
  final Color validColor;
  final Color invalidColor;

  /// Winkel eines Pfeils gegen „geradeaus“ in Grad, rechts positiv. `null`
  /// für einen Pfeil, den diese Leiste nicht kennt (wird als geradeaus
  /// gemalt). `uturn` hat eine eigene Form.
  static double? angleOf(String indication) => switch (indication) {
    'straight' || 'none' => 0,
    'slight right' => 45,
    'right' => 90,
    'sharp right' => 135,
    'slight left' => -45,
    'left' => -90,
    'sharp left' => -135,
    'merge to left' => -30,
    'merge to right' => 30,
    _ => null,
  };

  /// Welcher Pfeil der Spur der Route folgt: [RoutingLane.validIndication],
  /// sonst bei einer richtigen Spur mit nur einem Pfeil dieser.
  String? get followed {
    if (!highlighted) return null;
    return lane.validIndication ??
        (lane.indications.length == 1 ? lane.indications.single : null);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final indications = lane.indications.isEmpty
        ? const ['none']
        : lane.indications;
    final followedArrow = followed;
    // Erst die gedämpften Pfeile, dann der helle obenauf.
    final ordered = [
      for (final i in indications)
        if (!(highlighted && (followedArrow == null || i == followedArrow))) i,
      for (final i in indications)
        if (highlighted && (followedArrow == null || i == followedArrow)) i,
    ];
    for (final indication in ordered) {
      final bright =
          highlighted && (followedArrow == null || indication == followedArrow);
      _arrow(canvas, size, indication, bright ? validColor : invalidColor);
    }
  }

  void _arrow(Canvas canvas, Size size, String indication, Color color) {
    final stroke = size.width * 0.12;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;
    final base = Offset(size.width / 2, size.height * 0.9);
    final stem = size.height * 0.38;
    final bend = Offset(base.dx, base.dy - stem);
    final arm = size.height * 0.36;

    if (indication == 'uturn') {
      final r = size.width * 0.2;
      final top = bend.dy - r;
      final path = Path()
        ..moveTo(base.dx + r, base.dy)
        ..lineTo(base.dx + r, top + r)
        ..arcToPoint(Offset(base.dx - r, top + r), radius: Radius.circular(r))
        ..lineTo(base.dx - r, base.dy - stem * 0.4);
      canvas.drawPath(path, paint);
      _head(
        canvas,
        Offset(base.dx - r, base.dy - stem * 0.2),
        math.pi,
        stroke,
        fill,
      );
      return;
    }

    final degrees = angleOf(indication) ?? 0;
    final rad = degrees * math.pi / 180;
    // 0 Grad zeigt nach oben, positive Winkel nach rechts.
    final tip = bend + Offset(math.sin(rad) * arm, -math.cos(rad) * arm);
    final path = Path()
      ..moveTo(base.dx, base.dy)
      ..lineTo(bend.dx, bend.dy)
      ..lineTo(tip.dx, tip.dy);
    canvas.drawPath(path, paint);
    if (indication != 'none') {
      _head(canvas, tip, rad, stroke, fill);
    }
  }

  /// Pfeilspitze an [tip], in Richtung [rad] (0 = nach oben).
  void _head(Canvas canvas, Offset tip, double rad, double stroke, Paint fill) {
    final length = stroke * 2.4;
    final half = stroke * 1.6;
    final dir = Offset(math.sin(rad), -math.cos(rad));
    final normal = Offset(-dir.dy, dir.dx);
    final front = tip + dir * (length * 0.5);
    final back = tip - dir * (length * 0.5);
    canvas.drawPath(
      Path()
        ..moveTo(front.dx, front.dy)
        ..lineTo(back.dx + normal.dx * half, back.dy + normal.dy * half)
        ..lineTo(back.dx - normal.dx * half, back.dy - normal.dy * half)
        ..close(),
      fill,
    );
  }

  @override
  bool shouldRepaint(LaneArrowPainter old) =>
      old.lane != lane ||
      old.highlighted != highlighted ||
      old.validColor != validColor ||
      old.invalidColor != invalidColor;
}
