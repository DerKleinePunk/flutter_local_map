import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:map_local/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Waechter fuer den Ausstieg aus der App.
///
/// Auf dem Zielgeraet laeuft die App unter DRM/KMS im Vollbild: es gibt
/// keinen Fensterrahmen, kein X des Fenstermanagers, und der
/// ivi-homescreen-Embedder behandelt auf `flutter/platform` nur die
/// Zwischenablage - `SystemNavigator.pop` laeuft dort ins Leere. Fehlen
/// diese Bedienelemente, kommt man aus der App nur noch per SSH und
/// `pkill -x homescreen` heraus.
///
/// Das ist schon einmal passiert: das X war gebaut und getestet, dann lief
/// ein Build aus einem Worktree, der noch auf dem Commit davor stand, und
/// im Bundle war es wieder weg. Der Test faellt beiden Faellen auf - dem
/// geloeschten Code und dem veralteten Quellstand.
void main() {
  setUp(() {
    // `custom` vermeidet path_provider: der Downloader nimmt den Pfad
    // direkt und fasst keine Plattformkanaele an.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.storage_location': 'custom',
      'flutter.custom_storage_path': Directory.systemTemp.path,
    });
  });

  Future<void> pumpStartseite(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: MapHomePage()));
    // Kein pumpAndSettle: der Ladekreis dreht sich endlos, das wuerde
    // haengen. Ein Frame reicht, die Titelleiste steht sofort.
    await tester.pump();
  }

  testWidgets('die App bietet ein X zum Beenden', (tester) async {
    await pumpStartseite(tester);

    expect(
      find.byTooltip('Beenden (Strg+Q)'),
      findsOneWidget,
      reason:
          'Ohne dieses X kommt man auf dem Zielgeraet nur noch per SSH aus '
          'der App heraus - es gibt dort keinen Fensterrahmen.',
    );
    expect(
      find.byIcon(Icons.close),
      findsOneWidget,
      reason: 'Das Beenden-Symbol fehlt in der Titelleiste.',
    );
  });

  testWidgets('Strg+Q beendet ebenfalls', (tester) async {
    await pumpStartseite(tester);

    final belegungen = tester
        .widgetList<CallbackShortcuts>(find.byType(CallbackShortcuts))
        .expand((w) => w.bindings.keys)
        .whereType<SingleActivator>();

    expect(
      belegungen.any((a) => a.trigger == LogicalKeyboardKey.keyQ && a.control),
      isTrue,
      reason:
          'Strg+Q ist nicht belegt. Auf dem Zielgeraet ist die Zeigereingabe '
          'ein Touchpad an einer Funktastatur - das Kuerzel ist dort oft der '
          'einzige bequeme Weg.',
    );
  });

  testWidgets('das X fragt nach, statt sofort zu beenden', (tester) async {
    await pumpStartseite(tester);

    await tester.tap(find.byTooltip('Beenden (Strg+Q)'));
    await tester.pump();

    expect(
      find.text('Abbrechen'),
      findsOneWidget,
      reason:
          'Ohne Rueckfrage laesst ein Fehlgriff im Vollbild den Bildschirm '
          'schwarz zurueck, und zurueck kommt man nur ueber SSH.',
    );
  });

  testWidgets('die Schaltflaechen tragen einen Namen', (tester) async {
    await pumpStartseite(tester);

    // Ohne Zeiger gibt es keinen Tooltip. Im Semantikbaum standen die
    // Schaltflaechen sonst namenlos da - weder ein Screenreader noch die
    // MCP-Bedienung koennen sie dann auseinanderhalten.
    expect(find.bySemanticsLabel('Beenden'), findsWidgets);
    expect(find.bySemanticsLabel('Optionen'), findsWidgets);
  });
}
