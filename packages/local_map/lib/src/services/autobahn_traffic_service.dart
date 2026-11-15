import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../api/routing.dart';
import '../api/traffic.dart';
import 'traffic_geometry.dart';

/// [TrafficProvider] für die offene Schnittstelle der Autobahn GmbH des
/// Bundes (`verkehr.autobahn.de`): Staus, Sperrungen und Baustellen auf
/// deutschen Autobahnen. Ohne Schlüssel und ohne Anmeldung, aber auch ohne
/// offizielle Beschreibung - die Felder sind aus echten Antworten
/// abgelesen (Stand 2026-11).
///
/// Je Autobahn fragt der Dienst drei Endpunkte (`warning`, `closure`,
/// `roadworks`). Staus stecken in `warning`: Einträge mit
/// `abnormalTrafficType`, die Länge als Linie in Fahrtrichtung, der
/// Zeitverlust als `delayTimeValue` in Minuten.
///
/// Die Straßen werden nacheinander gefragt, nicht gleichzeitig - der Dienst
/// ist offen, eine Salve von Anfragen wäre unhöflich. Ein Zwischenspeicher
/// hält jede Straße [freshFor] lang frisch und überbrückt Funklöcher bis
/// [keepFor].
class AutobahnTrafficService implements TrafficProvider {
  AutobahnTrafficService({
    http.Client? client,
    Uri? baseUri,
    this.timeout = const Duration(seconds: 6),
    this.freshFor = const Duration(minutes: 5),
    this.keepFor = const Duration(hours: 6),
    this.maxRoads = 8,
    this.includePlanned = false,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       baseUri = baseUri ?? defaultBaseUri,
       _clock = clock ?? DateTime.now;

  static final Uri defaultBaseUri = Uri.parse(
    'https://verkehr.autobahn.de/o/autobahn/',
  );

  /// Die Endpunkte, die je Straße gefragt werden.
  static const List<String> services = ['warning', 'closure', 'roadworks'];

  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _clock;

  final Uri baseUri;

  /// Zeitgrenze je Anfrage.
  final Duration timeout;

  /// So lange gilt ein Abruf als frisch; bis dahin wird nicht neu gefragt.
  final Duration freshFor;

  /// So lange dient ein alter Stand als Ersatz, wenn der Abruf scheitert.
  /// Eine Baustelle steht Wochen, ein Stau nicht - älter wird es nicht.
  final Duration keepFor;

  /// Höchstens so viele Straßen je Abruf. Die übrigen fallen weg.
  final int maxRoads;

  /// Auch angekündigte Meldungen (`future: true`), etwa die Vollsperrung
  /// in der kommenden Nacht. Vorgabe: nur, was jetzt gilt.
  final bool includePlanned;

  final Map<String, _CacheEntry> _cache = {};

  /// Bringt eine Straßenbezeichnung in die Form der Schnittstelle: `A 3`,
  /// `a3` und `A3` werden zu `A3`. `null` für alles, was keine Autobahn ist.
  static String? normalizeRoad(String name) {
    final m = _roadPattern.firstMatch(name.trim());
    if (m == null) return null;
    final number = int.parse(m.group(1)!);
    if (number <= 0) return null;
    return 'A$number';
  }

  static final RegExp _roadPattern = RegExp(
    r'^(?:BAB|A)\s*0*(\d{1,3})$',
    caseSensitive: false,
  );

  /// Die Autobahnen, über die [route] führt (`A3`, `A9`), in
  /// Fahrtreihenfolge.
  ///
  /// Gelesen aus den Straßennamen der Manöver. Valhalla nennt dort die
  /// Nummer aus OSM als eigenen Eintrag (`A 3`), neben Namen oder
  /// Europastraße.
  static List<String> roadsOn(RoutingResult route) {
    final roads = <String>[];
    for (final maneuver in route.maneuvers) {
      for (final name in maneuver.streetNames) {
        for (final part in name.split(RegExp(r'[;/,]'))) {
          final road = normalizeRoad(part);
          if (road != null && !roads.contains(road)) roads.add(road);
        }
      }
    }
    return roads;
  }

  /// Meldungen für die Autobahnen der Route ([roadsOn]). Ohne Autobahn ein
  /// leerer Bericht, ohne Anfrage.
  @override
  Future<TrafficReport> incidentsAlong(RoutingResult route) =>
      incidents(roadsOn(route));

  /// Meldungen für [roads] (Schreibweisen wie bei [normalizeRoad]; alles,
  /// was keine Autobahn ist, fällt weg). Wirft nicht: Fehler stehen je
  /// Straße in [TrafficReport.sources].
  Future<TrafficReport> incidents(Iterable<String> roads) async {
    final wanted = <String>[];
    for (final raw in roads) {
      final road = normalizeRoad(raw);
      if (road == null || wanted.contains(road)) continue;
      wanted.add(road);
      if (wanted.length >= maxRoads) break;
    }

    final incidents = <TrafficIncident>[];
    final statuses = <TrafficSourceStatus>[];
    for (final road in wanted) {
      final now = _clock();
      final cached = _cache[road];
      if (cached != null && now.difference(cached.at) <= freshFor) {
        incidents.addAll(cached.incidents);
        statuses.add(
          TrafficSourceStatus(
            name: road,
            state: TrafficDataState.fresh,
            age: now.difference(cached.at),
          ),
        );
        continue;
      }

      try {
        final fetched = await _fetchRoad(road);
        _cache[road] = _CacheEntry(now, fetched);
        incidents.addAll(fetched);
        statuses.add(
          TrafficSourceStatus(
            name: road,
            state: TrafficDataState.fresh,
            age: Duration.zero,
          ),
        );
      } catch (e) {
        final error = e is TimeoutException
            ? 'keine Antwort in ${timeout.inMilliseconds} ms'
            : '$e';
        debugPrint('[verkehr] $road: $error');
        if (cached != null && now.difference(cached.at) <= keepFor) {
          incidents.addAll(cached.incidents);
          statuses.add(
            TrafficSourceStatus(
              name: road,
              state: TrafficDataState.cached,
              age: now.difference(cached.at),
              error: error,
            ),
          );
        } else {
          statuses.add(
            TrafficSourceStatus(
              name: road,
              state: TrafficDataState.failed,
              error: error,
            ),
          );
        }
      }
    }
    return TrafficReport(incidents: incidents, sources: statuses);
  }

  /// Alle drei Endpunkte einer Straße. Scheitert einer, scheitert die
  /// Straße: eine halbe Antwort sähe aus wie "weniger los" und würde den
  /// vollständigen alten Stand im Zwischenspeicher verdrängen.
  Future<List<TrafficIncident>> _fetchRoad(String road) async {
    final result = <TrafficIncident>[];
    final seen = <String>{};
    for (final service in services) {
      final uri = baseUri.resolve('$road/services/$service');
      final response = await _client
          .get(uri, headers: const {'accept': 'application/json'})
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw http.ClientException('$service: Status ${response.statusCode}');
      }
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      for (final incident in parseResponse(
        json,
        road: road,
        service: service,
        includePlanned: includePlanned,
      )) {
        // Dieselbe Meldung kann unter zwei Endpunkten stehen.
        if (seen.add(incident.id)) result.add(incident);
      }
    }
    return result;
  }

  /// Gibt den HTTP-Client frei, wenn der Dienst ihn selbst angelegt hat.
  void close() {
    if (_ownsClient) _client.close();
  }

  /// Liest eine Antwort eines Endpunkts. Öffentlich für Tests und für
  /// Gastgeber, die die Antworten auf anderem Weg holen.
  ///
  /// Einträge ohne Titel fallen weg - ein Symbol, das niemand deuten kann,
  /// hilft nicht. Ebenso angekündigte Meldungen, außer mit
  /// [includePlanned].
  static List<TrafficIncident> parseResponse(
    Object? json, {
    required String road,
    required String service,
    bool includePlanned = false,
  }) {
    final entries = _entries(json, service);
    final result = <TrafficIncident>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      final incident = _parseEntry(
        entry.cast<String, Object?>(),
        road: road,
        service: service,
        includePlanned: includePlanned,
      );
      if (incident != null) result.add(incident);
    }
    return result;
  }

  /// Die Liste einer Antwort: unter dem Namen des Endpunkts, sonst die
  /// einzige Liste der obersten Ebene.
  static List<Object?> _entries(Object? json, String service) {
    if (json is List) return json;
    if (json is! Map) return const [];
    final named = json[service];
    if (named is List) return named;
    final lists = json.values.whereType<List>().toList();
    return lists.length == 1 ? lists.single : const [];
  }

  static TrafficIncident? _parseEntry(
    Map<String, Object?> o, {
    required String road,
    required String service,
    required bool includePlanned,
  }) {
    if (!includePlanned && _bool(o['future'])) return null;

    final title = _text(o['title']).isNotEmpty
        ? _text(o['title'])
        : _text(o['subtitle']);
    if (title.isEmpty) return null;

    final display = _text(o['display_type']);
    final trafficType = _text(o['abnormalTrafficType']);
    final description = _text(o['description']);
    final blocked = _bool(o['isBlocked']);

    final TrafficIncidentKind kind;
    var blocksRoad = blocked;
    switch (service) {
      case 'warning' when trafficType.isNotEmpty:
        kind = TrafficIncidentKind.jam;
      case 'warning' when display == 'CLOSURE':
        kind = TrafficIncidentKind.closure;
        blocksRoad = true;
      case 'warning':
        kind = TrafficIncidentKind.warning;
      case 'closure':
        kind = TrafficIncidentKind.closure;
        // CLOSURE_ENTRY_EXIT ist nur eine Auf- oder Abfahrt.
        blocksRoad = blocked || display == 'CLOSURE';
      default:
        kind = TrafficIncidentKind.roadworks;
    }

    final line = thinLine(geoJsonLine(o['geometry']));
    final position = _coordinate(o['coordinate']) ?? line.firstOrNull;
    final direction = _text(o['subtitle']);

    return TrafficIncident(
      id: _text(o['identifier']).isNotEmpty
          ? _text(o['identifier'])
          : '$road:$service:$title',
      kind: kind,
      road: road,
      title: title,
      direction: direction.isEmpty ? null : direction,
      description: description,
      position: position,
      line: line,
      // Staus liegen in Fahrtrichtung (geprüft auf A2, A3, A9), ebenso die
      // Linie einer Vollsperrung. Baustellen-Linien nicht verlässlich.
      isDirectional:
          kind == TrafficIncidentKind.jam ||
          (kind == TrafficIncidentKind.closure && blocksRoad),
      blocksRoad: blocksRoad,
      delayMinutes: kind == TrafficIncidentKind.jam
          ? _positiveInt(o['delayTimeValue'])
          : null,
      averageSpeedKmh: kind == TrafficIncidentKind.jam
          ? _positiveInt(o['averageSpeed'])
          : null,
      jamLevel: kind == TrafficIncidentKind.jam
          ? _jamLevel(trafficType, description)
          : null,
      since: DateTime.tryParse(_text(o['startTimestamp'])),
    );
  }

  static TrafficJamLevel _jamLevel(String type, String description) {
    if (description.toLowerCase().contains('stillstand')) {
      return TrafficJamLevel.standstill;
    }
    return switch (type) {
      'STATIONARY_TRAFFIC' => TrafficJamLevel.standstill,
      'QUEUING_TRAFFIC' => TrafficJamLevel.queuing,
      'SLOW_TRAFFIC' => TrafficJamLevel.slow,
      'HEAVY_TRAFFIC' => TrafficJamLevel.heavy,
      _ => TrafficJamLevel.unknown,
    };
  }

  /// Text aus einer Zeichenkette oder einer Liste davon (Zeilen).
  static String _text(Object? value) {
    if (value is String) return value.trim();
    if (value is List) {
      return value.whereType<String>().map((s) => s.trim()).join('\n').trim();
    }
    return '';
  }

  /// Die Schnittstelle schreibt Wahrheitswerte mal als `true`, mal als
  /// `"true"`.
  static bool _bool(Object? value) =>
      value == true || (value is String && value.toLowerCase() == 'true');

  static int? _positiveInt(Object? value) {
    final n = parseNumber(value);
    if (n == null || n <= 0) return null;
    return n.round();
  }

  /// `{lat, long}` - die Schnittstelle schreibt `long`, nicht `lon`. Zahlen
  /// kommen auch als Text. 0/0 gilt als fehlend, nicht als Ort im Golf
  /// von Guinea.
  static LatLng? _coordinate(Object? value) {
    if (value is! Map) return null;
    final lat = parseNumber(value['lat'] ?? value['latitude']);
    final lon = parseNumber(value['long'] ?? value['lon'] ?? value['lng']);
    return validLatLng(lat, lon);
  }
}

class _CacheEntry {
  final DateTime at;
  final List<TrafficIncident> incidents;

  const _CacheEntry(this.at, this.incidents);
}
