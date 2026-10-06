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
/// Manöver noch kommen. Kommt, sobald ein Manöver das nächste wird. Wer die
/// Sprache erst erzeugen muss, rechnet sie jetzt vor - jede spätere
/// [Announcement] ist wörtlich einer dieser Sätze.
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
    this.lowercaseStarts = const <String>{},
  });

  /// Vorsatz für [meters] Meter, z. B. "In 300 Metern".
  final String Function(int meters) inMeters;

  /// Vorsatz für [km] Kilometer, z. B. "In 1 Kilometer".
  final String Function(int km) inKilometers;

  /// Beim Verlassen der Route, wenn neu berechnet wird.
  final String rerouting;

  /// Wörter, die nach dem Vorsatz klein geschrieben werden ("In 300 Metern
  /// links ..."). Für die Sprachausgabe egal, für das Log schöner.
  final Set<String> lowercaseStarts;

  static final AnnouncementTexts german = AnnouncementTexts(
    inMeters: (m) => 'In $m Metern',
    inKilometers: (km) => km == 1 ? 'In 1 Kilometer' : 'In $km Kilometern',
    rerouting: 'Die Route wird neu berechnet.',
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
    this.fastStepsMeters = const [1000, 400],
    this.slowStepsMeters = const [300],
    this.nowMinMeters = 40,
    this.nowSeconds = 3,
    this.minSpeedMps = 1.5,
    this.announcePost = false,
    this.texts,
  });

  /// Aus: [LocalMapController.announcements] bleibt still.
  final bool enabled;

  /// Ab dieser Geschwindigkeit gelten [fastStepsMeters]. 22,2 m/s = 80 km/h.
  final double fastSpeedMps;

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

    if (index != _current) {
      final previous = _current;
      _current = index;
      _firedSteps.clear();
      _firedNow = false;
      if (policy.announcePost &&
          previous != null &&
          previous < index &&
          !offRoute &&
          _isMoving(speedMps)) {
        final post = route.maneuvers[previous].verbalPost;
        if (post != null) {
          events.add(Announcement(post, AnnouncementPriority.info));
        }
      }
      events.add(AnnouncementPrepare(textsFor(index)));
    }

    if (offRoute || !_isMoving(speedMps)) return events;

    final maneuver = route.maneuvers[index];
    final distance = progress.distanceToNextManeuverMeters ?? 0;
    final speed = speedMps ?? 0;
    final nowMeters = _max(policy.nowMinMeters, policy.nowSeconds * speed);

    if (distance <= nowMeters) {
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

    final steps = speed >= policy.fastSpeedMps
        ? policy.fastStepsMeters
        : policy.slowStepsMeters;
    // Die engste Stufe, in der das Fahrzeug gerade ist. Liegt es schon weit
    // darunter (Route erst kurz vorher bekommen), passt der Satz nicht mehr.
    for (final step in steps.reversed) {
      if (distance <= step && distance > step * 0.6) {
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

  /// Alle Sätze, die für Manöver [index] kommen können.
  List<String> textsFor(int index) {
    final m = route.maneuvers[index];
    return <String>{
      for (final step in _allSteps) _stepText(m, step),
      _nowText(m),
      if (policy.announcePost && m.verbalPost != null) m.verbalPost!,
      texts.rerouting,
    }.toList();
  }

  bool _isMoving(double? speed) => speed == null || speed >= policy.minSpeedMps;

  String _nowText(RoutingManeuver m) => m.verbalPre ?? m.instruction;

  String _stepText(RoutingManeuver m, int meters) {
    final prefix = meters >= 1000 && meters % 1000 == 0
        ? texts.inKilometers(meters ~/ 1000)
        : texts.inMeters(meters);
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
