import '../api/routing.dart';
import 'route_progress.dart';

/// Wie dringend eine Ansage ist. Eine [maneuver]-Ansage darf eine laufende
/// [info]-Ansage abbrechen, nicht umgekehrt - das entscheidet der, der
/// spricht.
enum AnnouncementPriority { maneuver, info }

/// Was der Gastgeber zum Sprechen bekommt, über
/// [LocalMapController.announcements].
sealed class AnnouncementEvent {
  const AnnouncementEvent();
}

/// Sätze, die bald gesprochen werden können: alle, die für das nächste
/// Manöver noch kommen, dahinter die der Manöver kurz danach
/// ([AnnouncementPolicy.lookaheadMeters]). Kommt, sobald ein Manöver das
/// nächste wird. Wer die Sprache erst erzeugen muss, rechnet sie jetzt vor -
/// jede spätere [Announcement] ist wörtlich einer dieser Sätze. Die Liste
/// steht in der Reihenfolge, in der die Sätze gebraucht werden.
final class AnnouncementPrepare extends AnnouncementEvent {
  const AnnouncementPrepare(this.texts);

  final List<String> texts;

  @override
  String toString() => 'AnnouncementPrepare($texts)';
}

/// Jetzt sprechen.
final class Announcement extends AnnouncementEvent {
  const Announcement(this.text, this.priority);

  final String text;
  final AnnouncementPriority priority;

  @override
  String toString() => 'Announcement(${priority.name}: $text)';
}

/// Die festen Teile der Ansagen in einer Sprache. Die Manöver-Sätze selbst
/// kommen vom Router ([RoutingManeuver.verbalAlert] usw.) - deren Sprache
/// muss zu diesen Texten passen.
class AnnouncementTexts {
  const AnnouncementTexts({
    required this.inMeters,
    required this.inKilometers,
    required this.rerouting,
    required this.arrivalIn,
    this.lowercaseStarts = const <String>{},
  });

  /// Vorsatz für [meters] Meter, z. B. "In 300 Metern".
  final String Function(int meters) inMeters;

  /// Vorsatz für [km] Kilometer, z. B. "In 1 Kilometer".
  final String Function(int km) inKilometers;

  /// Wenn wegen des Verlassens der Route neu berechnet wird.
  final String rerouting;

  /// Vorwarnung vor dem Ziel, mit dem Vorsatz der Stufe ("In 300 Metern"):
  /// Die Sätze des Routers zum Ziel passen nicht hinter einen Vorsatz.
  final String Function(String prefix) arrivalIn;

  /// Wörter, die nach dem Vorsatz klein geschrieben werden ("In 300 Metern
  /// links ..."). Für die Sprachausgabe egal, für das Log schöner.
  final Set<String> lowercaseStarts;

  static final AnnouncementTexts german = AnnouncementTexts(
    inMeters: (m) => 'In $m Metern',
    inKilometers: (km) => km == 1 ? 'In 1 Kilometer' : 'In $km Kilometern',
    rerouting: 'Die Route wird neu berechnet.',
    arrivalIn: (prefix) => '$prefix erreichen Sie Ihr Ziel.',
    lowercaseStarts: const {
      'Links',
      'Rechts',
      'Leicht',
      'Scharf',
      'Wenden',
      'Geradeaus',
      'Weiter',
      'Im',
      'In',
      'Auf',
      'Am',
      'An',
      'Bei',
    },
  );

  static final AnnouncementTexts english = AnnouncementTexts(
    inMeters: (m) => 'In $m meters,',
    inKilometers: (km) => km == 1 ? 'In 1 kilometer,' : 'In $km kilometers,',
    rerouting: 'Recalculating the route.',
    arrivalIn: (prefix) => '$prefix you will arrive at your destination.',
    lowercaseStarts: const {
      'Turn',
      'Bear',
      'Make',
      'Keep',
      'Continue',
      'Enter',
      'Exit',
      'Take',
      'Merge',
      'Drive',
      'Head',
    },
  );
}

/// Wann angesagt wird.
class AnnouncementPolicy {
  const AnnouncementPolicy({
    this.enabled = true,
    this.fastSpeedMps = 22.2,
    this.fastHysteresisMps = 2.8,
    this.fastStepsMeters = const [1000, 400],
    this.slowStepsMeters = const [300],
    this.nowMinMeters = 40,
    this.nowSeconds = 3,
    this.minSpeedMps = 1.5,
    this.announcePost = false,
    this.lookaheadMeters = 500,
    this.lookaheadManeuvers = 2,
    this.texts,
  });

  /// Aus: [LocalMapController.announcements] bleibt still.
  final bool enabled;

  /// Ab dieser Geschwindigkeit gelten [fastStepsMeters]. 22,2 m/s = 80 km/h.
  final double fastSpeedMps;

  /// Zurück zu [slowStepsMeters] erst unter [fastSpeedMps] minus diesem
  /// Wert, damit die Klasse bei 80 km/h nicht hin und her springt (jeder
  /// Wechsel bringt ein neues [AnnouncementPrepare]). 2,8 m/s = 10 km/h.
  final double fastHysteresisMps;

  /// Entfernungen der Vorwarnungen, absteigend. Nur diese Werte erscheinen in
  /// den Sätzen - nie eine gerundete Live-Entfernung, sonst trifft die
  /// Ansage den vorab gerechneten Satz nicht.
  final List<int> fastStepsMeters;
  final List<int> slowStepsMeters;

  /// "Jetzt" kommt ab max([nowMinMeters], [nowSeconds] Fahrt) vor dem
  /// Manöver.
  final double nowMinMeters;
  final double nowSeconds;

  /// Darunter steht das Fahrzeug, und es wird nichts angesagt.
  final double minSpeedMps;

  /// Auch den Satz nach dem Manöver sagen ("200 Meter weiter auf B 62.").
  final bool announcePost;

  /// Das Prepare nennt auch die Sätze der Manöver, die höchstens so weit
  /// hinter dem nächsten liegen, damit sie fertig sind, wenn Manöver dicht
  /// aufeinander folgen (Start, Stadt). 0 = nur das nächste Manöver.
  final double lookaheadMeters;

  /// Höchstens so viele Manöver aus [lookaheadMeters].
  final int lookaheadManeuvers;

  /// Feste Satzteile; `null` = [AnnouncementTexts.german].
  final AnnouncementTexts? texts;
}

/// Entscheidet Fix für Fix, was angesagt wird. Gehört zu einer Route.
class ManeuverAnnouncer {
  ManeuverAnnouncer(this.route, [this.policy = const AnnouncementPolicy()])
    : texts = policy.texts ?? AnnouncementTexts.german;

  final RoutingResult route;
  final AnnouncementPolicy policy;
  final AnnouncementTexts texts;

  int? _current;
  final Set<int> _firedSteps = <int>{};
  bool _firedNow = false;

  /// Tempoklasse: [AnnouncementPolicy.fastStepsMeters] oder
  /// [AnnouncementPolicy.slowStepsMeters].
  bool _fast = false;

  /// Klasse, für die das letzte [AnnouncementPrepare] galt.
  bool? _preparedFast;

  /// Alle Vorwarn-Stufen, die überhaupt vorkommen können, absteigend.
  List<int> get _allSteps =>
      ({...policy.fastStepsMeters, ...policy.slowStepsMeters}.toList()
        ..sort((a, b) => b - a));

  /// Nimmt den Fortschritt eines Fixes auf und liefert, was zu tun ist.
  List<AnnouncementEvent> update(
    RouteProgress progress, {
    double? speedMps,
    bool offRoute = false,
  }) {
    if (!policy.enabled) return const [];
    final events = <AnnouncementEvent>[];
    final index = progress.nextManeuverIndex;
    if (index == null) return const [];

    // Ein Manöver, das schon dran war, kommt nicht wieder - auch nicht, wenn
    // die Position zurückspringt (GPS-Sprung, Aufzeichnung von vorn).
    final current = _current;
    if (current != null && index < current) return const [];

    final speed = speedMps;
    if (speed != null && _isMoving(speed)) {
      if (!_fast && speed >= policy.fastSpeedMps) {
        _fast = true;
      } else if (_fast &&
          speed < policy.fastSpeedMps - policy.fastHysteresisMps) {
        _fast = false;
      }
    }

    final distance = progress.distanceToNextManeuverMeters;
    final maneuver = route.maneuvers[index];
    final toManeuver = distance ?? 0;
    final nowMeters = _max(
      policy.nowMinMeters,
      policy.nowSeconds * (speedMps ?? 0),
    );

    if (index != current) {
      final previous = current;
      _current = index;
      _firedSteps.clear();
      _firedNow = false;
      // Schon beim ersten Fix am Ziel (Neustart mit geladener Route): Das
      // Ziel war vorher schon dran, "Ziel erreicht" kommt nicht noch einmal.
      if (previous == null &&
          _isArrival(maneuver.type) &&
          toManeuver <= nowMeters) {
        _firedNow = true;
        _firedSteps.addAll(_allSteps);
      }
      if (policy.announcePost &&
          previous != null &&
          !offRoute &&
          _isMoving(speedMps)) {
        final post = route.maneuvers[previous].verbalPost;
        if (post != null) {
          events.add(Announcement(post, AnnouncementPriority.info));
        }
      }
      events.add(
        AnnouncementPrepare(textsFor(index, distanceMeters: distance)),
      );
      _preparedFast = _fast;
    } else if (_preparedFast != _fast && !_firedNow) {
      // Andere Stufen als vorbereitet: die jetzt passenden nachreichen.
      events.add(
        AnnouncementPrepare(textsFor(index, distanceMeters: distance)),
      );
      _preparedFast = _fast;
    }

    if (offRoute || !_isMoving(speedMps)) return events;

    if (toManeuver <= nowMeters) {
      if (!_firedNow) {
        _firedNow = true;
        // Was man an Stufen verpasst hat, kommt nicht mehr.
        _firedSteps.addAll(_allSteps);
        events.add(
          Announcement(_nowText(maneuver), AnnouncementPriority.maneuver),
        );
      }
      return events;
    }

    final steps = _steps;
    // Die engste Stufe, in der das Fahrzeug gerade ist. Liegt es schon weit
    // darunter (Route erst kurz vorher bekommen), passt der Satz nicht mehr.
    for (final step in steps.reversed) {
      if (_inStep(toManeuver, step)) {
        if (_firedSteps.contains(step)) break;
        for (final s in _allSteps) {
          if (s >= step) _firedSteps.add(s);
        }
        events.add(
          Announcement(
            _stepText(maneuver, step),
            AnnouncementPriority.maneuver,
          ),
        );
        break;
      }
    }
    return events;
  }

  /// Satz beim Verlassen der Route, wenn neu berechnet wird.
  Announcement rerouting() =>
      Announcement(texts.rerouting, AnnouncementPriority.info);

  /// Die Sätze, die für Manöver [index] beim jetzigen Tempo noch kommen
  /// können, in der Reihenfolge, in der sie gesprochen würden, dahinter die
  /// der Manöver kurz danach. Wer vorab rechnet, rechnet so zuerst, was
  /// zuerst gebraucht wird.
  ///
  /// [distanceMeters] ist der Weg bis Manöver [index]; Stufen, deren
  /// Bereich schon hinter dem Fahrzeug liegt, kommen nicht mehr und fehlen
  /// dann. `null` = alle offenen Stufen.
  List<String> textsFor(int index, {double? distanceMeters}) {
    // Eine Stufe kommt nur, solange das Manöver weiter als 60 % von ihr
    // entfernt ist ([_inStep]).
    return <String>{
      ..._maneuverTexts(
        index,
        (step) =>
            !_firedSteps.contains(step) &&
            (distanceMeters == null || distanceMeters > step * 0.6),
      ),
      for (final next in _lookahead(index))
        // Das Manöver wird das nächste, wenn es so weit entfernt ist wie
        // vom vorigen.
        ..._maneuverTexts(next, (step) => _legMeters(next - 1) > step * 0.6),
      texts.rerouting,
    }.toList();
  }

  List<String> _maneuverTexts(int index, bool Function(int step) withStep) {
    final m = route.maneuvers[index];
    return [
      for (final step in _steps)
        if (withStep(step)) _stepText(m, step),
      _nowText(m),
      if (policy.announcePost && m.verbalPost != null) m.verbalPost!,
    ];
  }

  /// Manöver nach [index], die höchstens [AnnouncementPolicy.lookaheadMeters]
  /// dahinter beginnen.
  List<int> _lookahead(int index) {
    final result = <int>[];
    var meters = 0.0;
    for (
      var next = index + 1;
      next < route.maneuvers.length &&
          result.length < policy.lookaheadManeuvers;
      next++
    ) {
      meters += _legMeters(next - 1);
      if (meters > policy.lookaheadMeters) break;
      result.add(next);
    }
    return result;
  }

  /// Weg von Manöver [index] bis zum folgenden.
  double _legMeters(int index) => route.maneuvers[index].lengthKm * 1000;

  List<int> get _steps {
    final steps = List<int>.of(
      _fast ? policy.fastStepsMeters : policy.slowStepsMeters,
    )..sort((a, b) => b - a);
    return steps;
  }

  /// Im Bereich der Stufe [step]: höchstens [step], aber mehr als 60 % davon
  /// entfernt. Weiter darunter passt der Satz nicht mehr.
  bool _inStep(double distance, int step) =>
      distance <= step && distance > step * 0.6;

  bool _isMoving(double? speed) => speed == null || speed >= policy.minSpeedMps;

  String _nowText(RoutingManeuver m) => m.verbalPre ?? m.instruction;

  String _stepText(RoutingManeuver m, int meters) {
    final prefix = meters >= 1000 && meters % 1000 == 0
        ? texts.inKilometers(meters ~/ 1000)
        : texts.inMeters(meters);
    if (_isArrival(m.type)) return texts.arrivalIn(prefix);
    return '$prefix ${_lowerStart(m.verbalAlert ?? m.instruction)}';
  }

  String _lowerStart(String sentence) {
    final space = sentence.indexOf(' ');
    final first = space < 0 ? sentence : sentence.substring(0, space);
    if (!texts.lowercaseStarts.contains(first)) return sentence;
    return sentence[0].toLowerCase() + sentence.substring(1);
  }
}

double _max(double a, double b) => a > b ? a : b;

/// Valhalla: 4 Ziel, 5 Ziel rechts, 6 Ziel links.
bool _isArrival(int? type) => type == 4 || type == 5 || type == 6;
