# Plan: local_map in Carnine2

Angelegt: 2026-09-24. Grundlage war eine Bestandsaufnahme beider Repos (flutter_local_map bei `eef48b5`). Die Abschnitte ab „Ziel“ beschreiben den Ausgangsplan; den aktuellen Stand zeigt der Abschnitt „Stand“.

## Stand (2026-09-25, abends)

**Die Karte läuft in Carnine2**, auf beiden Pis: auf carnine-pc (Carnine2-Sitzung, Debos-Image) und auf jeep-pi
(normales Debian, Backend dort nativ gebaut). Gegenüber dem Zeitplan unten sind wir damit rund vier Wochen voraus.

- **Phase 0** (emb_cli): fertig. `feature/emb-cli` ist der Integrationszweig in carnine2.
- **Phase 1** (Lib entkoppeln): fertig. Seit `local_map-v0.3.0` keine festen deutschen Texte in `MapView`
  (`errorBuilder`, `MapError.category`) und keine Hessen-Vorgaben mehr (`MapConfig.center` optional, Start in
  der Mitte der Kacheln; das alte Setup heißt `MapConfig.hessen`). Seit `local_map-v0.4.0` sind auch
  Suchfeld, Download-Overlay und Speicherort-Dialog übersetzbar (`PlaceSearchTexts` usw., englische
  Vorgabe, `.german`). Carnine2 nutzt diese drei nicht und bleibt auf 0.3.0.
- **Phase 2** (Navigationsmodus): fertig und auf dem Panel abgenommen (Route auf der gefahrenen Strecke,
  flüssig mit Drehung auf Zoom 16).
- **Phase 3** (Backend): alle fünf RPCs des `NavigationService` (ADR-021) umgesetzt und gegen echtes
  Valhalla bestätigt. `GetReplayRoute` liefert die ganze Adnan-Tour (45,2 km, 20 Manöver). Valhalla 3.9.0
  läuft auf beiden Pis als systemd-Dienst. Seit carnine2 v0.4.0 (`db67938` auf `feature/backend`):
  **GPS-Maus** an der Seriellen (jeder NMEA-Empfänger, Baudrate einstellbar, udev-Link `/dev/gps`,
  Wochen-Rollover-Korrektur), live auf dem Pi getestet; **Systemuhr aus GPS**, solange NTP nicht
  synchronisiert ist (kein RTC im Auto); **Fahrtenbuch** mit rohem NMEA je Fahrt, live schaltbar über
  das neue `rpc SetTrackRecording` (`NavigationStatus` Felder 5–7, rein additiv).
- **Phase 4** (Kartenseite): läuft. Navigationsmodus-Umschaltung abgenommen. carnine2 bindet die Lib über
  eine **feste Marke** ein (`ref: local_map-v0.3.0`), nicht mehr über `master`; `scripts/styles.zip` liegt
  nicht mehr im Baum, `pub get` braucht kein `GIT_LFS_SKIP_SMUDGE` mehr.
  `feature/map-page` ist nach `feature/emb-cli` gemergt (`d3d9f2f`); dort stehen seit `eaaac26` auch
  `MapLayerStyle.backgroundColor` (`#0e0e0e`, kein heller Blitz beim Öffnen) und die Suche „genauer Name
  vor Präfix-Treffer“ im Backend. Die Kartenseite läuft auf carnine-pc und auf jeep-pi.
  Der Stil ist für das 7-Zoll-Panel aufgehellt und versioniert (carnine2 #28 zu, `7a25193`).
  carnine2 **v0.4.0** (`4d26100`) bringt Valhalla und Karten-Drop-in im Image mit; die Kartendaten kommen
  weiter per Skript.
- **Phase 5**: begonnen. Karte und Musik laufen auf carnine-pc gleichzeitig (homescreen ca. 90 % eines
  Kerns). Dauertest zum Einfrieren bestanden: 3 h 22 min Karte am Stück, nie eingefroren, 0 verlorene
  Page-Flips, ~56 fps. Ein zweiter Dauertest mit dem 0.3.0-Image zeigt kein Einfrieren und kein Leck
  (homescreen flach bei 204–208 MB RSS). Die GPS-Maus läuft am Pi, noch nicht im Auto.
  In Arbeit (Carnine2-Sitzung): KL15-Netzteil (AuPrV1_1) am Test-Pi – es sendet nur Text und reagiert noch
  nicht auf Befehle. Es lässt beim Abschalten nur 15 s, das Herunterfahren dauert aber 29 s, weil
  `valhalla.service` so lange zum Stoppen braucht.
  Offen: Fahrt im Auto, eigene Messetour, Speichermessung gegen 4 GB.

**Regel für Lib-Änderungen:** Jede Änderung, die carnine2 braucht, bekommt eine neue Marke
`local_map-vX.Y.Z` mit Eintrag in `packages/local_map/CHANGELOG.md`. carnine2 wechselt die Marke bewusst.

## Ziel

Die Karte aus `packages/local_map` läuft als Kartenseite in Carnine2 – im Carnine2-Design, mit Routing aus dem Rust-Backend statt aus einem separaten Valhalla-Webserver, mit einem Navigationsmodus, der die Karte in Fahrtrichtung dreht, und innerhalb von 4 GB RAM auf dem Pi 4.

## Ausgangslage

### local_map heute

- `MapView` (`packages/local_map/lib/src/widgets/map_view.dart`, 1700 Zeilen) ist ein einziges Widget, das alles selbst macht: Kacheln, Style, Geocoder, Routing, GPS-Simulator, Marker und die komplette Bedien-UI (Suchfelder, Chips, Badges, Zoom-Knöpfe). Zustand ist privat, es gibt keine Callbacks nach außen.
- **Keine einzige Schnittstelle** in `lib/` – kein `abstract class`. Routing (`ValhallaRoutingService`, HTTP auf `127.0.0.1:8002`), GPS (`GpsNmeaSimulatorService`) und Geocoder (Singleton) werden in `initState` fest erzeugt.
- Die Routing-Modelle (`RoutingPoint`, `RoutingResult`, `RoutingManeuver`) sind schon neutral benannt und taugen als Vertrag.
- Manöver werden von Valhalla geliefert und geparst, aber nirgends angezeigt.
- **Kein Navigationsmodus:** Die Karte folgt dem Simulator nur per `move()` alle 5 s. Rotation ist als Geste bewusst abgeschaltet, Positionsdaten haben weder Kurs noch Geschwindigkeit, eine echte GPS-Quelle gibt es nicht.
- Deutsche Texte, Hessen-Defaults (`MapConfig.hessen`, Mittelpunkt Alsfeld) und `127.0.0.1:8002` stehen hart in der Lib.
- Drei Pflicht-Forks über `dependency_overrides` (`vector_map_tiles`, `flutter_map_mbtiles`, `vector_map_tiles_mbtiles`) – müssen in jedem Gastgeber wiederholt werden.
- Getestet auf **ivi-homescreen** (emb, Flutter 3.47.5) – derselben Kette, auf die Carnine2 umzieht.

### Carnine2 heute

- Rust-Backend (tokio/tonic, ein Crate) und Flutter-Frontend, verbunden **nur über gRPC auf einem Unix-Socket** (`/run/carnine/carnine.sock`). ADR-013: Frontend ist reine Darstellung, Logik gehört ins Backend. ADR-015: gRPC ist der einzige Vertrag, Änderungen daran brauchen vorher ein ADR.
- Das Backend kann bisher nur Medien/Audio. **Kein Navigations-, GPS- oder Karten-Service**, keine Geo-Crates, kein Valhalla.
- Kartenseite `lib/features/maps/presentation/maps_content.dart` ist ein **statischer Platzhalter** mit gemalter Beispielroute, Suchleiste, Abbiegekarte („450 m, Lindenallee“), Zoom-Knöpfen und Fahrtleiste. Die Overlays passen zum Design und können über einer echten Karte stehen bleiben.
- Design: OLED-Schwarz mit Neon-Cyan/Magenta (`AppColors`), Touch-Ziele ≥ 76 dp, feste Fläche 1024×600, davon ca. 928×560 für den Inhalt. Nur Dark-Theme. Alle Texte in 15 Sprachen.
- Embedder ist heute **flutter-pi**; der Umzug auf emb_cli/ivi-homescreen ist beschlossen (siehe Entscheidungen, Phase 0).
- Qualitätsziele: 60 FPS, Start < 3 s, App-RAM < 200 MB, offline.

## Zu Valhalla und dem Container

Die Einschätzung stimmt im Kern, mit einer Einschränkung:

- **Den Container braucht es auf dem Pi ohnehin nicht.** `scripts/valhalla/cross_compile_valhalla_pi.sh` und `deploy_valhalla_pi.sh` bauen und verteilen schon native aarch64-Binaries nach `/opt/valhalla`. Der `docker run` in `docs/valhalla-offline-setup.md` ist der ältere Weg.
- `valhalla_service` ist nur ein dünner HTTP-Server um die Bibliothek `libvalhalla`. Deren Einstieg `valhalla::tyr::actor_t` nimmt dieselbe JSON-Anfrage entgegen und gibt dieselbe JSON-Antwort zurück – ganz ohne Server. Diese Bibliothek kann das Rust-Backend direkt einbinden (C++-Bindings, z. B. mit `cxx`).
- **Was man damit spart:** einen eigenen Prozess mit eigenem Kachel-Cache, einen eigenen systemd-Dienst, einen zweiten Konfigurations- und Log-Weg und den Port. Das zählt bei 4 GB. **Was man kaum spart:** den HTTP-Aufruf selbst – eine Anfrage über Loopback kostet Mikrosekunden, die Routenberechnung dauert um Größenordnungen länger. Der Gewinn liegt im Betrieb und im Speicher, nicht in der Latenz.
- Dazu passt es zur Carnine2-Architektur: Routing ist Logik, also Backend, und das Frontend spricht nur gRPC.

**Empfehlung:** `libvalhalla` in das Rust-Backend einbinden, hinter einem neuen gRPC-`NavigationService`. Den HTTP-Weg in der Lib als zweite Implementierung behalten – für die Demo-App und für Tests auf dem Entwicklungsrechner.

## Entscheidungen

Getroffen am 2026-09-24:

- **Embedder: Carnine2 zieht auf emb_cli / ivi-homescreen um.** Das Projekt hat deutlich mehr Fahrt, und flutter-pi unterstützt die aktuellen Flutter-Versionen nicht – wann das kommt, ist offen. Damit laufen Karte und Carnine2 auf derselben Kette (Flutter 3.47.5, `drm-kms-egl`), und die bisherigen Messungen der Karte gelten weiter. Der Umbau ist eine eigene Arbeitsaufgabe (Phase 0). Die ADR-017/019-Umgehung für verlorene DRM-Commits in flutter-pi muss dabei neu bewertet werden.
- **3D/Kameraneigung:** An 3D arbeitet das emb_cli-Umfeld, das ist aber Alpha. Nicht für die Messe einplanen.
- **GPS:** GPS-Maus über USB/seriell mit NMEA, eingelesen im Rust-Backend.
- **Testdaten:** Hessen reicht (Kacheln, Namen, Valhalla-Kacheln).
- **Einbindung per Git.** local_map bleibt ein eigenständiges Open-Source-Paket, das auch andere ohne Carnine2 nutzen können. Folge: Die Lib darf nichts Carnine2-Spezifisches enthalten, bekommt Versions-Tags, und das README muss die drei Pflicht-Overrides deutlich nennen.

- **Ortssuche im Backend** (rusqlite mit FTS5 auf `germany_names.db`). Kacheln liest die Karte weiter direkt aus der MBTiles-Datei – alles andere wäre für das Rendern zu langsam. Die Lib bekommt für die Suche nur eine Schnittstelle; `OfflineGeocoder` bleibt als Implementierung für die Demo-App.

Erledigt: ADR-021 in carnine2 legt den `NavigationService` fest. Ob die Ausnahme „Kacheln liest das Frontend direkt“ und der Wechsel des Embedders dort mit abgedeckt sind, klärt die Carnine2-Sitzung.

## Messe am 6. November 2026

Bis dahin bleiben gut sechs Wochen. Das reicht nicht für alles in diesem Plan, also wird für die Messe geschnitten.

**Muss laufen:**

- Carnine2 auf emb_cli, auf dem Pi mit dem Waveshare-Panel.
- Kartenseite mit echter Karte (Hessen), dunkler Style im Carnine2-Design.
- Ziel suchen, Route berechnen, Route auf der Karte.
- Navigationsmodus: Karte folgt und dreht sich mit dem Kurs, Abbiegekarte und Fahrtleiste mit echten Werten.
- Position aus der GPS-Maus, auf dem Messestand aus einem **NMEA-Replay** (drinnen gibt es keinen Empfang). Das Replay muss sich im Backend genauso anfühlen wie die echte Maus.

**Für die Messe bewusst vereinfacht:**

- **Valhalla zunächst als nativer Dienst** (`valhalla_service`, systemd, kein Container) – aber nur das Backend spricht mit ihm. Der gRPC-`NavigationService` ist von Anfang an der endgültige Vertrag; das Frontend merkt später nicht, wenn das Backend auf eingebundenes `libvalhalla` wechselt. So hängt der Messetermin nicht an den C++-Bindings, die das größte technische Risiko im Plan sind.
- Keine Off-Route-Erkennung und Neuberechnung, keine Sprachansagen, keine Via-Punkte, kein 3D.
- ~~Texte zunächst Deutsch und Englisch~~ – die Kartenseite hat alle 15 Sprachen.

**Grober Zeitplan:**

| Woche | ab | Inhalt |
|---|---|---|
| 1 | 28.09. | Carnine2 auf emb_cli bauen und auf dem Pi starten (Phase 0). Parallel: Schnittstellen der Lib entwerfen und den gRPC-`NavigationService` festlegen – beides zusammen, sie hängen aneinander. |
| 2 | 05.10. | Lib entkoppeln (Phase 1). Backend: NMEA-Einleser für seriell und Replay, Valhalla als Dienst auf dem Pi. |
| 3 | 12.10. | Navigationsmodus in der Lib (Phase 2). Backend: `StartRoute`, `StreamPosition`, `StreamGuidance`, Suche. |
| 4 | 19.10. | Kartenseite in Carnine2 anschließen (Phase 4), dunkler Style. |
| 5 | 26.10. | Durchgehend auf dem Pi: Fahrt per Replay, Speicher, Bildrate, Einfrieren. Fehler beheben. Fahrt mit dem Pi im Auto, dabei die Messetour aufzeichnen. |
| 6 | 02.11. | Puffer, Messeaufbau, Replay-Tour vorbereiten. Kein neues Feature mehr. |

Wenn eine Woche rutscht, fällt zuerst der dunkle Style (dann heller Navigationsstyle), danach die Suche (dann fest hinterlegte Ziele im Demo-Menü). Karte, Route und drehender Navigationsmodus sind der Kern und bleiben.

## Phasen

### Phase 0 – Carnine2 auf emb_cli (carnine2)

- Frontend mit `emb cross --target rpi4-trixie --backend drm-kms-egl` bauen statt mit `flutterpi_tool`, Flutter 3.47.5 aus dem emb-Workspace.
- `carnine-frontend.service` und `.deb` auf `homescreen -b … -f` umstellen; Abhängigkeiten wie seatd übernehmen (siehe README dieses Repos, Abschnitt Embedded Linux).
- flutter-pi-Besonderheiten prüfen: UI-Ready-Handshake mit erzwungenen Frames (ADR-017/019), `CARNINE_FLUTTER_PI`, `window_manager`.
- Abnahme: Carnine2 startet auf dem Pi mit Panel, Medienwiedergabe funktioniert wie vorher.

### Phase 1 – Lib entkoppeln (flutter_local_map)

Ziel: `local_map` ist eine reine Kartenkomponente, die Demo-App baut ihre Bedienung selbst.

- Schnittstellen einführen:
  - `RoutingProvider` – `route(from, to, {via})`, `isAvailable`. `ValhallaHttpRoutingProvider` ist die heutige Klasse.
  - `PositionSource` – `Stream<PositionFix>` mit Position, **Kurs, Geschwindigkeit, Genauigkeit**, Zeit. Der NMEA-Simulator wird eine Implementierung und übernimmt Kurs und Geschwindigkeit aus dem RMC-Satz – die Tourdatei enthält sie, der heutige Parser wirft sie nur weg. Abspielen im Originaltakt (1 Hz) statt alle 5 s.
  - `PlaceSearch` – ersetzt das Geocoder-Singleton. `OfflineGeocoder` wird eine Implementierung.
  - `MapLogger` – Hook statt `debugPrint`.
- `LocalMapController`: Route, Start/Ziel, Position, Folgemodus und Kamera von außen setzen und lesen, Ereignisse als Streams oder `ChangeNotifier` (passt zu Carnine2, dort ist Riverpod/Bloc verboten).
- `MapView` aufteilen: Kartenebenen (Kacheln, Route, Marker, Positionspfeil) bleiben in der Lib, alles in `_buildMapControls` wandert in die Demo-App (`lib/`). Marker- und Routenfarben kommen als Parameter bzw. aus einem `LocalMapTheme`.
- Aus der Lib entfernen: deutsche UI-Texte, Hessen-Defaults, die fest verdrahtete Valhalla-Adresse im Fehlertext.
- Die Demo-App verhält sich danach wie heute – das ist der Abnahmetest der Phase.

### Phase 2 – Navigationsmodus (flutter_local_map)

- Kamera dreht nach Kurs (`MapController.moveAndRotate`), Fahrzeug im unteren Drittel statt in der Mitte, Kurs geglättet und bei Stillstand eingefroren (GPS-Kurs springt unter ~5 km/h).
- Positionspfeil dreht mit dem Kurs; Knopf „Norden oben“ zurück.
- Interpolation zwischen Fixes, damit die Karte bei 1 Hz nicht springt.
- Manöver als Daten nach außen (nächstes Manöver, Distanz dorthin, Restzeit, Restweg). **Anzeigen tut es der Gastgeber** – in Carnine2 die vorhandene Abbiegekarte und Fahrtleiste.
- Risiken, die früh zu messen sind: Wie verhalten sich Beschriftungen von `vector_map_tiles` bei gedrehter Karte (Straßennamen, Lesbarkeit)? Was kostet das ständige Drehen auf dem Pi an Kachel-Neuzeichnungen? Kamera-Neigung (3D-Perspektive) kann flutter_map grundsätzlich nicht; die gäbe es nur mit einem Wechsel auf MapLibre (siehe TODO.md).
- Off-Route-Erkennung und Neuberechnung: Erkennung gehört eher ins Backend (Map-Matching), die Lib muss nur eine neue Route übernehmen können.

### Phase 3 – Navigation im Backend (carnine2)

- ADR schreiben (siehe oben), dann `NavigationService` in `carnine.proto`: `SearchPlaces`, `StartRoute`/`CancelRoute`, `StreamGuidance` (Manöver, Fortschritt, Neuberechnung) und `StreamPosition`.
- Für die Messe: Backend spricht `valhalla_service` als nativen Dienst an (systemd, Hessen-Kacheln).
- Danach: `libvalhalla` für aarch64 als Bibliothek bauen (die vorhandenen Cross-Compile-Skripte liefern bisher die Binaries) und über `cxx` einbinden, den Dienst abschaffen. Vorher prüfen, ob es ein brauchbares Crate dafür gibt.
- Positionsquelle im Backend: GPS-Maus über USB/seriell, NMEA direkt einlesen (`$GPRMC`/`$GPGGA`, Kurs und Geschwindigkeit stehen im RMC-Satz). Dazu ein Replay-Modus mit den vorhandenen NMEA-Touren für Tests ohne Auto und für den Messestand.
- Ortssuche mit rusqlite auf `germany_names.db`.
- Navigationsansagen: ADR-016/017 sehen Navigation schon als Audioquelle mit höchster Priorität und Ducking vor – daran andocken, sobald Manöver fließen.

### Phase 4 – Kartenseite in Carnine2 (carnine2 Frontend)

- `MapsContent`: Der gemalte `_MapBackground` wird durch `MapView` ersetzt. Suchleiste, Abbiegekarte, Zoom-Knöpfe und Fahrtleiste bleiben und werden an den `LocalMapController` und den gRPC-`NavigationService` angeschlossen.
- gRPC-Implementierungen der Lib-Schnittstellen (`RoutingProvider`, `PositionSource`, `PlaceSearch`) im Frontend – dünne Adapter, keine Logik.
- **Dunkler Kartenstyle** passend zu `AppColors` (Fläche `#0E0E0E`, Route Cyan `#81ECFF`, Ziel Magenta). Heute gibt es nur helle Styles. Straßenhierarchie muss auf Schwarz lesbar bleiben.
- Die drei Fork-Overrides in `src/frontend/pubspec.yaml` übernehmen.
- Texte über `AppTextKey`, in allen 15 Sprachen.

### Phase 5 – Auslieferung und Messung

- Kartendaten ins Image bzw. nach `/var/lib/carnine`: vorerst Hessen (`hessen.mbtiles` 2,2 GB, Namen, Valhalla-Kacheln), später `germany-vec.mbtiles` (17 GB). Rechte für den Dienstnutzer `carnine`.
- Frontend-`.deb` um die nativen Abhängigkeiten ergänzen, die local_map braucht (sqlite).
- Messung auf dem Pi gegen 4 GB: Backend mit Valhalla + Frontend mit Karte + Medienwiedergabe gleichzeitig. Ladezeit der Karte, Bildrate beim Fahren mit Rotation, Speicher.
- Ohne RTC ist die Uhrzeit nach dem Boot bis zum NTP- oder GPS-Fix falsch – die ETA sollte die GPS-Zeit nehmen.

## Reihenfolge und Abhängigkeiten

Phase 0 und Phase 1 laufen parallel, sie berühren verschiedene Repos. Phase 2 hängt nur an Phase 1. Phase 3 kann beginnen, sobald die Schnittstellen aus Phase 1 und der gRPC-Vertrag stehen – beide werden deshalb in Woche 1 gemeinsam festgelegt. Phase 4 braucht 0, 1 und die ersten Aufrufe aus 3.

## Replay-Tour für die Messe

Es gibt genau eine Aufzeichnung: `scripts/GpsTest/GPS-Adnan-Tour.txt`.

- 3093 Fixes im 1-Hz-Takt, 51 min, 45 km, bis 114 km/h, liegt vollständig in Hessen (50,27–50,41 N, 9,36–9,44 O).
- **Kurs und Geschwindigkeit stehen drin** (Kursfeld in 3010 von 3093 RMC-Sätzen). Für den drehenden Navigationsmodus reicht die Datei also ohne Nachrechnen.
- Eine Rundfahrt: Start und Ende am selben Ort, Wendepunkt 15 km Luftlinie südlich nach etwa der Hälfte. Rund 5 min davon Stand (unter 3 km/h) – dort muss der Kurs eingefroren werden, sonst dreht die Karte im Stand wild.
- ~~Für die Demo passt die Route nur, wenn Valhalla dieselbe Strecke wählt wie die Aufzeichnung.~~ Gelöst: Die Route entsteht per Map-Matching aus der Tour selbst (`/trace_route`, in der Lib `routeAlongTrace`, im Backend `GetReplayRoute`). Weil Valhalla eine Spur, die dieselbe Straße zurückfährt, nur halb matcht, wird sie an Selbstüberlappungen geteilt (25 m / 300 m) und wieder zusammengesetzt. Die Route liegt damit genau auf der gefahrenen Strecke.

Empfehlung: Mit der GPS-Maus, sobald das Backend sie liest, **eine eigene Messetour aufzeichnen** – kurz (10–15 min, damit sie auf dem Stand oft durchläuft), mit ein paar deutlichen Abbiegungen und genau der Route, die Valhalla für das Demo-Ziel berechnet. Das ist zugleich der erste **Hardwaretest mit dem Pi im Auto**: Stromversorgung im Bordnetz, GPS-Maus am USB, NMEA-Einleser, Panel bei Tageslicht. Die Adnan-Tour bleibt Rückfallebene.
