import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:latlong2/latlong.dart';
import 'package:xml/xml.dart';

import '../api/routing.dart';
import '../api/traffic.dart';
import 'traffic_geometry.dart';

/// [TrafficProvider] für Verkehrsmeldungen im europäischen Format DATEX II
/// (Version 2 und 3, `SituationPublication`): Staus, Sperrungen,
/// Baustellen, Unfälle.
///
/// DATEX II ist das Format der Länder und der Mobilithek. Woher die Daten
/// kommen, stellt der Gastgeber ein, die Lib legt sich nicht fest:
///
/// - offene Dateien ohne Anmeldung, etwa MobiData BW
///   (`https://api.mobidata-bw.de/datasets/traffic/incidents/incidents_lmsbw.datex2.xml`);
/// - ein Abo der Mobilithek: Adresse aus [mobilithekV2] / [mobilithekV3],
///   Maschinenzertifikat über [Datex2TrafficService.withClientCertificate].
///
/// Eine Quelle deckt ein Gebiet ab, nicht eine Straße: Jeder Abruf holt den
/// ganzen Stand, behalten werden nur Meldungen in [corridorMeters] um die
/// Route. Gelesen wird in einem eigenen Isolate - ein Land sind schnell
/// ein, zwei Megabyte XML.
///
/// Verwertet werden Meldungen mit Koordinaten (`locationForDisplay`,
/// Linien als `gmlLineString`, `linearByCoordinates`, TPEG-Punkte,
/// Punkte). Meldungen, die ihren Ort nur als ALERT-C-Code (TMC-Tabelle)
/// nennen, fallen weg.
class Datex2TrafficService implements TrafficProvider {
  Datex2TrafficService({
    required this.uri,
    this.name = 'DATEX II',
    http.Client? client,
    this.headers = const {},
    this.timeout = const Duration(seconds: 20),
    this.freshFor = const Duration(minutes: 2),
    this.keepFor = const Duration(hours: 6),
    this.corridorMeters = 2000,
    this.includePlanned = false,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _clock = clock ?? DateTime.now;

  /// Wie [Datex2TrafficService.new], mit einem Client-Zertifikat für
  /// gegenseitiges TLS - so verlangt es die Mobilithek beim Abruf eines
  /// Abos. [pkcs12] ist der Inhalt der `.p12`-Datei, die die Mobilithek
  /// zuschickt (Zertifikat und Schlüssel), [password] ihr Kennwort.
  ///
  /// Wirft eine [TlsException], wenn die Datei nicht passt oder das
  /// Kennwort falsch ist - beim Einstellen, nicht erst beim Abruf.
  factory Datex2TrafficService.withClientCertificate({
    required Uri uri,
    required List<int> pkcs12,
    String? password,
    String name = 'DATEX II',
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 20),
    Duration freshFor = const Duration(minutes: 2),
    Duration keepFor = const Duration(hours: 6),
    double corridorMeters = 2000,
    bool includePlanned = false,
    DateTime Function()? clock,
  }) {
    final context = SecurityContext(withTrustedRoots: true)
      ..useCertificateChainBytes(pkcs12, password: password)
      ..usePrivateKeyBytes(pkcs12, password: password);
    return Datex2TrafficService._owning(
      uri: uri,
      name: name,
      client: IOClient(HttpClient(context: context)),
      headers: headers,
      timeout: timeout,
      freshFor: freshFor,
      keepFor: keepFor,
      corridorMeters: corridorMeters,
      includePlanned: includePlanned,
      clock: clock,
    );
  }

  Datex2TrafficService._owning({
    required this.uri,
    required this.name,
    required http.Client client,
    required this.headers,
    required this.timeout,
    required this.freshFor,
    required this.keepFor,
    required this.corridorMeters,
    required this.includePlanned,
    DateTime Function()? clock,
  }) : _client = client,
       _ownsClient = true,
       _clock = clock ?? DateTime.now;

  /// Abruf eines Mobilithek-Abos auf ein DATEX-II-v2-Angebot
  /// (Client Pull, Schnittstellenbeschreibung Kap. 6.3).
  static Uri mobilithekV2(String subscriptionId) => Uri.parse(
    'https://mobilithek.info:8443/mobilithek/api/v1.0/subscription/'
    '$subscriptionId/clientPullService?subscriptionID=$subscriptionId',
  );

  /// Abruf eines Mobilithek-Abos auf ein DATEX-II-v3-Angebot
  /// (Client Pull HTTPS, Schnittstellenbeschreibung Kap. 7.2.3.2.1).
  static Uri mobilithekV3(String subscriptionId) => Uri.parse(
    'https://mobilithek.info:8443/mobilithek/api/v1.0/subscription/'
    'datexv3?subscriptionID=$subscriptionId',
  );

  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _clock;

  /// Woher die Meldungen kommen.
  final Uri uri;

  /// Name der Quelle in [TrafficSourceStatus.name] und im Protokoll.
  final String name;

  /// Zusätzliche Kopfzeilen je Anfrage, etwa ein Schlüssel.
  final Map<String, String> headers;

  /// Zeitgrenze je Anfrage, Lesen eingeschlossen.
  final Duration timeout;

  /// So lange gilt ein Abruf als frisch; bis dahin wird nicht neu gefragt.
  final Duration freshFor;

  /// So lange dient ein alter Stand als Ersatz, wenn der Abruf scheitert.
  final Duration keepFor;

  /// Nur Meldungen, die so nah an der Route liegen, kommen in den Bericht.
  /// Welche wirklich auf ihr liegen, entscheidet [RouteTraffic.match].
  final double corridorMeters;

  /// Auch Meldungen, die noch nicht gelten (Baustelle ab nächster Woche).
  final bool includePlanned;

  List<TrafficIncident>? _cached;
  DateTime? _cachedAt;
  String? _lastModified;

  @override
  Future<TrafficReport> incidentsAlong(RoutingResult route) async {
    final all = await _incidents();
    return TrafficReport(
      incidents: filterNear(all.incidents, route, corridorMeters),
      sources: [all.status],
    );
  }

  /// Alle Meldungen der Quelle, ohne Auswahl nach Route. Wirft nicht.
  Future<TrafficReport> incidents() async {
    final all = await _incidents();
    return TrafficReport(incidents: all.incidents, sources: [all.status]);
  }

  Future<({List<TrafficIncident> incidents, TrafficSourceStatus status})>
  _incidents() async {
    final now = _clock();
    final cached = _cached;
    final cachedAt = _cachedAt;
    if (cached != null &&
        cachedAt != null &&
        now.difference(cachedAt) <= freshFor) {
      return (
        incidents: cached,
        status: TrafficSourceStatus(
          name: name,
          state: TrafficDataState.fresh,
          age: now.difference(cachedAt),
        ),
      );
    }

    try {
      final fetched = await _fetch(now);
      if (fetched != null) {
        _cached = fetched;
      } else if (cached == null) {
        // 204/304 ohne eigenen Stand: nichts zu zeigen, aber auch kein
        // Beleg für "frei".
        throw const _NoData();
      }
      _cachedAt = now;
      return (
        incidents: _cached!,
        status: TrafficSourceStatus(
          name: name,
          state: TrafficDataState.fresh,
          age: Duration.zero,
        ),
      );
    } catch (e) {
      final error = switch (e) {
        TimeoutException() => 'keine Antwort in ${timeout.inSeconds} s',
        _NoData() => 'Quelle hat noch keine Daten',
        _ => '$e',
      };
      debugPrint('[verkehr] $name: $error');
      if (cached != null &&
          cachedAt != null &&
          now.difference(cachedAt) <= keepFor) {
        return (
          incidents: cached,
          status: TrafficSourceStatus(
            name: name,
            state: TrafficDataState.cached,
            age: now.difference(cachedAt),
            error: error,
          ),
        );
      }
      return (
        incidents: const <TrafficIncident>[],
        status: TrafficSourceStatus(
          name: name,
          state: TrafficDataState.failed,
          error: error,
        ),
      );
    }
  }

  /// Die Meldungen eines Abrufs, `null` bei 204/304 (nichts Neues).
  Future<List<TrafficIncident>?> _fetch(DateTime now) async {
    final request = http.Request('GET', uri)
      ..headers.addAll({
        'accept': 'text/xml, application/xml',
        // Die Mobilithek antwortet ohne diese Angabe mit 400/406.
        'accept-encoding': 'gzip',
        if (_lastModified != null && _cached != null)
          'if-modified-since': _lastModified!,
        ...headers,
      });
    final response = await _client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(timeout);
    switch (response.statusCode) {
      case 200:
        break;
      case 204 || 304:
        return null;
      default:
        throw http.ClientException('Status ${response.statusCode}');
    }
    _lastModified = response.headers['last-modified'];
    // Ein Client, der gzip nicht selbst auspackt (die Kopfzeile oben ist
    // von Hand gesetzt), liefert die rohen Bytes.
    var bytes = response.bodyBytes;
    if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      bytes = Uint8List.fromList(gzip.decode(bytes));
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    return compute(
      _parseInIsolate,
      _ParseJob(text, now, includePlanned),
      debugLabel: 'datex2',
    );
  }

  /// Gibt den HTTP-Client frei, wenn der Dienst ihn selbst angelegt hat.
  void close() {
    if (_ownsClient) _client.close();
  }

  /// Meldungen in [corridorMeters] um [route]: grob über das umgebende
  /// Rechteck, dann je Meldung der nächste Routenpunkt. Genügt für die
  /// Vorauswahl; die genaue Zuordnung macht [RouteTraffic.match].
  static List<TrafficIncident> filterNear(
    List<TrafficIncident> incidents,
    RoutingResult route,
    double corridorMeters,
  ) {
    final points = [for (final p in route.geometry) p.toLatLng()];
    if (points.isEmpty) return const [];
    final dLat = corridorMeters / 111320;
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in points) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLon = math.min(minLon, p.longitude);
      maxLon = math.max(maxLon, p.longitude);
    }
    final cosLat = math.cos(((minLat + maxLat) / 2) * math.pi / 180).abs();
    final dLon = dLat / math.max(cosLat, 0.1);
    bool inBox(LatLng p) =>
        p.latitude >= minLat - dLat &&
        p.latitude <= maxLat + dLat &&
        p.longitude >= minLon - dLon &&
        p.longitude <= maxLon + dLon;

    // Die Route ausgedünnt, damit der Abstand je Meldung nicht über
    // Tausende Punkte läuft. Stützpunkte höchstens corridor/2 auseinander
    // halten den Fehler klein.
    final step = math.max(corridorMeters / 2, 200);
    final sample = <LatLng>[points.first];
    const distance = Distance();
    for (final p in points.skip(1)) {
      if (distance.as(LengthUnit.Meter, sample.last, p) >= step) {
        sample.add(p);
      }
    }
    if (sample.last != points.last) sample.add(points.last);

    bool near(LatLng p) {
      if (!inBox(p)) return false;
      for (final s in sample) {
        if (distance.as(LengthUnit.Meter, s, p) <= corridorMeters + step) {
          return true;
        }
      }
      return false;
    }

    return [
      for (final i in incidents)
        if ((i.position != null && near(i.position!)) || i.line.any(near)) i,
    ];
  }

  /// Liest eine `SituationPublication` (DATEX II v2 oder v3, auch in einem
  /// `messageContainer` oder einem SOAP-Umschlag). Öffentlich für Tests und
  /// für Gastgeber, die die Daten auf anderem Weg holen.
  ///
  /// Je Situation entsteht eine Meldung je Fahrtrichtung: Eine Situation
  /// "in beiden Richtungen gesperrt" kommt als zwei Records mit
  /// gegenläufigen Linien. Die Records einer Richtung werden zu einer
  /// Meldung zusammengelegt; die Art richtet sich nach dem schwersten
  /// (Sperrung vor Stau vor Baustelle vor Warnung).
  static List<TrafficIncident> parse(
    String xml, {
    DateTime? now,
    bool includePlanned = false,
  }) {
    final document = XmlDocument.parse(xml);
    final at = now ?? DateTime.now();
    final result = <TrafficIncident>[];
    for (final situation in document.descendantElements.where(
      (e) => e.localName == 'situation',
    )) {
      final groups = <String, List<_Record>>{};
      for (final element in situation.childElements.where(
        (e) => e.localName == 'situationRecord',
      )) {
        final record = _Record.read(element);
        if (record == null) continue;
        if (!record.isValidAt(at, includePlanned: includePlanned)) continue;
        groups.putIfAbsent(record.geometryKey, () => []).add(record);
      }
      final id = situation.getAttribute('id') ?? '';
      var index = 0;
      for (final records in groups.values) {
        final incident = _merge(
          groups.length == 1 ? id : '$id#${index++}',
          records,
        );
        if (incident != null) result.add(incident);
      }
    }
    return result;
  }

  static TrafficIncident? _merge(String id, List<_Record> records) {
    records.sort((a, b) => b.rank.compareTo(a.rank));
    final main = records.first;
    if (main.kind == null) return null;
    final kind = main.kind!;
    final position = main.position ?? main.line.firstOrNull;
    if (position == null) return null;

    final description = records
        .map((r) => r.description)
        .firstWhere((d) => d.isNotEmpty, orElse: () => '');
    final firstLine = description.split('\n').first.trim();
    final title = firstLine.isNotEmpty ? firstLine : _kindTitle(kind);
    final road = records
        .map((r) => r.roadNumber)
        .firstWhere((r) => r.isNotEmpty, orElse: () => _roadFrom(firstLine));
    final blocksRoad = records.any((r) => r.blocksRoad);
    int? delay;
    for (final r in records) {
      final d = r.delaySeconds;
      if (d != null && d > 0) delay = math.max(delay ?? 0, (d / 60).round());
    }
    final jamLevel = kind == TrafficIncidentKind.jam
        ? records
              .map((r) => r.jamLevel)
              .firstWhere((l) => l != null, orElse: () => null)
        : null;
    final directional =
        main.line.length >= 2 &&
        !main.bothDirections &&
        (kind == TrafficIncidentKind.jam ||
            (kind == TrafficIncidentKind.closure && blocksRoad));

    return TrafficIncident(
      id: id.isEmpty ? '${position.latitude},${position.longitude}' : id,
      kind: kind,
      road: road,
      title: title,
      direction: _directionFrom(firstLine),
      description: description,
      position: position,
      line: main.line,
      isDirectional: directional,
      blocksRoad: blocksRoad,
      delayMinutes: kind == TrafficIncidentKind.jam && delay != null
          ? math.max(1, delay)
          : null,
      jamLevel: jamLevel,
      since: records
          .map((r) => r.since)
          .whereType<DateTime>()
          .fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a),
    );
  }

  static String _kindTitle(TrafficIncidentKind kind) => switch (kind) {
    TrafficIncidentKind.jam => 'Stau',
    TrafficIncidentKind.closure => 'Sperrung',
    TrafficIncidentKind.roadworks => 'Baustelle',
    TrafficIncidentKind.warning => 'Verkehrsmeldung',
  };

  /// `A5 Karlsruhe Richtung Basel` -> `A5`, `L 1100 ...` -> `L1100`.
  static String _roadFrom(String line) {
    final m = RegExp(r'\b([ABLK])\s?(\d{1,4})\b').firstMatch(line);
    return m == null ? '' : '${m.group(1)}${m.group(2)}';
  }

  /// `A5 Karlsruhe Richtung Basel` -> `Basel`.
  static String? _directionFrom(String line) {
    final m = RegExp(r'\bRichtung\s+(.+)$').firstMatch(line);
    final d = m?.group(1)?.trim();
    return d == null || d.isEmpty ? null : d;
  }
}

class _NoData implements Exception {
  const _NoData();
}

class _ParseJob {
  final String xml;
  final DateTime now;
  final bool includePlanned;

  const _ParseJob(this.xml, this.now, this.includePlanned);
}

List<TrafficIncident> _parseInIsolate(_ParseJob job) =>
    Datex2TrafficService.parse(
      job.xml,
      now: job.now,
      includePlanned: job.includePlanned,
    );

/// Ein `situationRecord`, gelesen nach lokalen Namen - v2 und v3
/// unterscheiden sich vor allem in den Namensräumen.
class _Record {
  final TrafficIncidentKind? kind;
  final TrafficJamLevel? jamLevel;
  final bool blocksRoad;
  final String description;
  final String roadNumber;
  final LatLng? position;
  final List<LatLng> line;
  final bool bothDirections;
  final int? delaySeconds;
  final DateTime? since;
  final String validityStatus;
  final DateTime? start;
  final DateTime? end;

  const _Record({
    required this.kind,
    required this.jamLevel,
    required this.blocksRoad,
    required this.description,
    required this.roadNumber,
    required this.position,
    required this.line,
    required this.bothDirections,
    required this.delaySeconds,
    required this.since,
    required this.validityStatus,
    required this.start,
    required this.end,
  });

  /// Sperrung vor Stau vor Baustelle vor Warnung; ohne Art ganz hinten.
  int get rank => switch (kind) {
    TrafficIncidentKind.closure => blocksRoad ? 5 : 3,
    TrafficIncidentKind.jam => 4,
    TrafficIncidentKind.roadworks => 2,
    TrafficIncidentKind.warning => 1,
    null => 0,
  };

  /// Records mit derselben Linie gehören zu einer Fahrtrichtung.
  String get geometryKey {
    if (line.length >= 2) {
      String p(LatLng l) =>
          '${l.latitude.toStringAsFixed(4)},${l.longitude.toStringAsFixed(4)}';
      return '${p(line.first)}>${p(line.last)}';
    }
    final pos = position;
    return pos == null
        ? ''
        : '${pos.latitude.toStringAsFixed(4)},'
              '${pos.longitude.toStringAsFixed(4)}';
  }

  bool isValidAt(DateTime now, {required bool includePlanned}) {
    switch (validityStatus) {
      case 'suspended':
        return false;
      case 'active':
        return true;
      default:
        if (end != null && end!.isBefore(now)) return false;
        if (!includePlanned && start != null && start!.isAfter(now)) {
          return false;
        }
        return true;
    }
  }

  /// `xsi:type` ohne Präfix. Nach lokalem Namen gesucht: Ein Record hat
  /// kein anderes Attribut `type`.
  static String _type(XmlElement e) {
    final t =
        e.attributes
            .where((a) => a.name.local == 'type')
            .map((a) => a.value)
            .firstOrNull ??
        '';
    final colon = t.indexOf(':');
    return colon < 0 ? t : t.substring(colon + 1);
  }

  static _Record? read(XmlElement e) {
    final type = _type(e);
    String child(String name) => _firstText(e, name);

    TrafficIncidentKind? kind;
    TrafficJamLevel? jamLevel;
    var blocks = false;
    switch (type) {
      case 'AbnormalTraffic':
        final t = child('abnormalTrafficType');
        // Ohne Art ist es die Folge einer Baustelle, kein eigener Stau.
        if (t.isNotEmpty) {
          kind = TrafficIncidentKind.jam;
          jamLevel = switch (t) {
            'stationaryTraffic' => TrafficJamLevel.standstill,
            'queuingTraffic' => TrafficJamLevel.queuing,
            'slowTraffic' => TrafficJamLevel.slow,
            'heavyTraffic' => TrafficJamLevel.heavy,
            _ => TrafficJamLevel.unknown,
          };
        }
      case 'RoadOrCarriagewayOrLaneManagement':
        final t = child('roadOrCarriagewayOrLaneManagementType');
        if (t == 'roadClosed' || t == 'carriagewayClosures') {
          kind = TrafficIncidentKind.closure;
          blocks = true;
        } else if (t.contains('Closed') || t.contains('Closure')) {
          // Fahrstreifen, Auf- oder Abfahrt.
          kind = TrafficIncidentKind.closure;
        } else {
          kind = TrafficIncidentKind.roadworks;
        }
      case 'MaintenanceWorks' || 'ConstructionWorks' || 'Roadworks':
        kind = TrafficIncidentKind.roadworks;
      case 'Accident' ||
          'VehicleObstruction' ||
          'GeneralObstruction' ||
          'AnimalPresenceObstruction' ||
          'EnvironmentalObstruction' ||
          'InfrastructureDamageObstruction' ||
          'PoorEnvironmentConditions' ||
          'WeatherRelatedRoadConditions' ||
          'NonWeatherRelatedRoadConditions' ||
          'PublicEvent' ||
          'DisturbanceActivity' ||
          'EquipmentOrSystemFault':
        kind = TrafficIncidentKind.warning;
      default:
        // Umleitungen, Hinweise der Leitzentrale: nur als Beiwerk.
        kind = null;
    }

    final location = _locationOf(e);
    return _Record(
      kind: kind,
      jamLevel: jamLevel,
      blocksRoad: blocks,
      description: _comment(e),
      roadNumber: child('roadNumber').replaceAll(' ', ''),
      position: location.position,
      line: location.line,
      bothDirections: location.bothDirections,
      delaySeconds: parseNumber(child('delayTimeValue'))?.round(),
      since: DateTime.tryParse(child('overallStartTime')),
      validityStatus: child('validityStatus'),
      start: DateTime.tryParse(child('overallStartTime')),
      end: DateTime.tryParse(child('overallEndTime')),
    );
  }

  /// Der Text der Meldung: der `description`-Kommentar, sonst der erste.
  static String _comment(XmlElement e) {
    String? first;
    for (final c in e.descendantElements.where(
      (x) => x.localName == 'generalPublicComment',
    )) {
      final value = c.descendantElements
          .where((x) => x.localName == 'value')
          .map((x) => x.innerText.trim())
          .firstWhere((t) => t.isNotEmpty, orElse: () => '');
      if (value.isEmpty) continue;
      final type = _firstText(c, 'commentType');
      if (type == 'description') return value;
      first ??= value;
    }
    return first ?? '';
  }

  static ({LatLng? position, List<LatLng> line, bool bothDirections})
  _locationOf(XmlElement record) {
    // v2: groupOfLocations, v3: locationReference.
    final loc = record.childElements
        .where(
          (x) =>
              x.localName == 'groupOfLocations' ||
              x.localName == 'locationReference',
        )
        .firstOrNull;
    if (loc == null) {
      return (position: null, line: const <LatLng>[], bothDirections: false);
    }
    final display = _point(
      loc.descendantElements
          .where(
            (x) =>
                x.localName == 'locationForDisplay' ||
                x.localName == 'coordinatesForDisplay',
          )
          .firstOrNull,
    );

    var line = <LatLng>[];
    // Mehrere Teilstücke (v3 ItineraryByIndexedLocations) hintereinander.
    for (final gml in loc.descendantElements.where(
      (x) => x.localName == 'gmlLineString',
    )) {
      line.addAll(_gmlLine(gml));
    }
    if (line.length < 2) {
      line = _linearByCoordinates(loc);
    }
    if (line.length < 2) {
      line = _tpegLine(loc);
    }
    final point =
        display ??
        _point(
          loc.descendantElements
              .where((x) => x.localName == 'pointCoordinates')
              .firstOrNull,
        );
    return (
      position: point ?? line.firstOrNull,
      line: line.length >= 2 ? thinLine(line) : const <LatLng>[],
      bothDirections: _firstText(loc, 'bothDirections') == 'true',
    );
  }

  /// v2-Erweiterung: `<coordinates>lon,lat lon,lat</coordinates>`;
  /// v3: `<posList>lat lon lat lon</posList>`.
  static List<LatLng> _gmlLine(XmlElement gml) {
    final points = <LatLng>[];
    final coordinates = _firstText(gml, 'coordinates');
    if (coordinates.isNotEmpty) {
      for (final pair in coordinates.split(RegExp(r'\s+'))) {
        final parts = pair.split(',');
        if (parts.length < 2) continue;
        final p = validLatLng(
          double.tryParse(parts[1]),
          double.tryParse(parts[0]),
        );
        if (p != null) points.add(p);
      }
      return points;
    }
    final posList = _firstText(gml, 'posList');
    if (posList.isNotEmpty) {
      final n = posList
          .split(RegExp(r'\s+'))
          .map(double.tryParse)
          .toList(growable: false);
      for (var i = 0; i + 1 < n.length; i += 2) {
        final p = validLatLng(n[i], n[i + 1]);
        if (p != null) points.add(p);
      }
    }
    return points;
  }

  static List<LatLng> _linearByCoordinates(XmlElement loc) {
    final lbc = loc.descendantElements
        .where((x) => x.localName == 'linearByCoordinates')
        .firstOrNull;
    if (lbc == null) return const [];
    final start = _point(_childNamed(lbc, 'start'));
    final end = _point(_childNamed(lbc, 'end'));
    final inner =
        lbc.childElements.where((x) => x.localName == 'intermediate').toList()
          ..sort(
            (a, b) => (int.tryParse(a.getAttribute('index') ?? '') ?? 0)
                .compareTo(int.tryParse(b.getAttribute('index') ?? '') ?? 0),
          );
    return [?start, for (final i in inner) ?_point(i), ?end];
  }

  /// TPEG `from` -> `to`, nur die beiden Endpunkte.
  static List<LatLng> _tpegLine(XmlElement loc) {
    final tpeg = loc.descendantElements
        .where((x) => x.localName == 'tpegLinearLocation')
        .firstOrNull;
    if (tpeg == null) return const [];
    final from = _point(_childNamed(tpeg, 'from'));
    final to = _point(_childNamed(tpeg, 'to'));
    return from != null && to != null ? [from, to] : const [];
  }

  static XmlElement? _childNamed(XmlElement e, String name) =>
      e.childElements.where((x) => x.localName == name).firstOrNull;

  /// Ein Punkt aus `latitude`/`longitude` darunter (direkt oder eine
  /// Ebene tiefer, etwa `pointCoordinates`).
  static LatLng? _point(XmlElement? e) {
    if (e == null) return null;
    final lat = _firstText(e, 'latitude');
    final lon = _firstText(e, 'longitude');
    return validLatLng(double.tryParse(lat), double.tryParse(lon));
  }

  static String _firstText(XmlElement e, String localName) {
    for (final x in e.descendantElements) {
      if (x.localName == localName) return x.innerText.trim();
    }
    return '';
  }
}
