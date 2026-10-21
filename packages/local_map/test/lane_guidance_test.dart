import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_map/local_map.dart';

const _lanes = [
  RoutingLane(indications: ['straight'], valid: true, active: true),
  RoutingLane(
    indications: ['straight', 'slight right'],
    valid: true,
    validIndication: 'straight',
  ),
  RoutingLane(indications: ['slight right'], valid: false),
  RoutingLane(indications: ['slight right'], valid: false),
];

Widget _host(List<RoutingLane> lanes) => MaterialApp(
  home: Scaffold(
    body: Center(child: LaneGuidance(lanes: lanes)),
  ),
);

void main() {
  testWidgets('eine Spalte je Spur und eine Ansage für Screenreader', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(_lanes));
    for (var i = 0; i < 4; i++) {
      expect(find.byKey(ValueKey('lane-$i')), findsOneWidget);
    }
    // Eine Spur ist die richtige (active): nur sie zählt, nicht die zweite,
    // von der man noch einmal wechseln müsste.
    expect(find.bySemanticsLabel('Spuren: 1 von 4 richtig'), findsOneWidget);

    // Ohne active zählen die gültigen.
    await tester.pumpWidget(
      _host(const [
        RoutingLane(indications: ['straight'], valid: true),
        RoutingLane(indications: ['straight'], valid: true),
        RoutingLane(indications: ['right'], valid: false),
      ]),
    );
    expect(find.bySemanticsLabel('Spuren: 2 von 3 richtig'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('ohne Spuren nimmt es keinen Platz ein', (tester) async {
    await tester.pumpWidget(_host(const []));
    expect(tester.getSize(find.byType(LaneGuidance)), Size.zero);
  });

  test('Winkel der Pfeile, rechts positiv', () {
    expect(LaneArrowPainter.angleOf('straight'), 0);
    expect(LaneArrowPainter.angleOf('none'), 0);
    expect(LaneArrowPainter.angleOf('slight right'), 45);
    expect(LaneArrowPainter.angleOf('right'), 90);
    expect(LaneArrowPainter.angleOf('sharp left'), -135);
    expect(LaneArrowPainter.angleOf('uturn'), isNull);
    expect(LaneArrowPainter.angleOf('merge_to_left'), isNull);
  });

  test('hell ist nur der Pfeil, dem die Route folgt', () {
    LaneArrowPainter painter(RoutingLane lane) => LaneArrowPainter(
      lane: lane,
      validColor: Colors.white,
      invalidColor: Colors.grey,
    );
    expect(painter(_lanes[0]).followed, 'straight');
    expect(painter(_lanes[1]).followed, 'straight');
    expect(painter(_lanes[2]).followed, isNull);
    // Mehrere Pfeile ohne Angabe, welcher: alle hell.
    expect(
      painter(
        const RoutingLane(indications: ['left', 'straight'], valid: true),
      ).followed,
      isNull,
    );
  });

  testWidgets('malt jede Pfeilform ohne Fehler', (tester) async {
    await tester.pumpWidget(
      _host([
        for (final i in [
          'straight',
          'slight right',
          'right',
          'sharp right',
          'uturn',
          'sharp left',
          'left',
          'slight left',
          'none',
          'merge_to_left',
        ])
          RoutingLane(indications: [i], valid: i == 'right'),
        const RoutingLane(indications: [], valid: false),
      ]),
    );
    expect(tester.takeException(), isNull);
  });
}
