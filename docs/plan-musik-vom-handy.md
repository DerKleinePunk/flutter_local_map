# Plan: Musik vom Handy (A2DP + AVRCP)

Stand: 23.11.2026, Fassung 4b. Entschieden bis auf den USB-Hub (Punkt E). Der Vorab-Test auf dem Test-Pi (Pi 4) ist bestanden.
Gebaut ist davon noch nichts. Image und Backend: carnine2. Oberfläche: Frontend (Ticket). Geplant ab Version 0.25.0.
Verwandter Plan: [plan-ble-kopplung.md](plan-ble-kopplung.md) (Handy-App über BLE). Beide nutzen denselben Koppel-Dialog.

## Ziel

Das Handy spielt seine Musik über die Lautsprecher im Auto. CarNine ist dabei der Bluetooth-Lautsprecher (**A2DP-Sink**).
Auf dem Bildschirm stehen Titel und Interpret, und Play, Pause, Weiter und Zurück gehen ans Handy (**AVRCP**).
Navigationsansagen bleiben verständlich.

**Nicht in diesem Schritt:** Telefonieren über das Auto (HFP, eigener Schritt danach, siehe unten), Cover-Bilder vom Handy, eine eigene Handy-App (die bleibt der BLE-Plan).

## Vorgaben

- AVRCP gehört dazu.
- WLAN läuft über einen USB-Stick. Bluetooth hat den eingebauten Chip des Pi für sich, das eingebaute WLAN ist aus.
- Klassisches Koppeln ist erlaubt, weil A2DP es braucht. Nur mit Codevergleich, nie mit fester PIN.
- Getestet und freigegeben wird nur für den **Raspberry Pi 4**. Andere Boards prüfen wir später gesondert.

## Womit: bluez-alsa, das Backend mischt selbst

| Weg | Bewertung |
|---|---|
| **bluez-alsa (`bluealsa`), das Backend liest den Ton und mischt ihn** | **Gewählt.** Kleiner Dienst ohne Soundserver (im Test 9,7 MB, etwa 1 % eines Kerns). Die Soundkarte bleibt allein beim Backend, der Vorrang der Ansagen ist schon da |
| bluez-alsa mit `bluealsa-aplay` direkt auf die Soundkarte | Nein. Ein zweites Programm würde dieselbe Karte öffnen (auf vc4-hdmi gibt es kein dmix). Mit dem AC-3-Ausgang (Loopback + Kodierer) wäre es ein Weg an der Kette vorbei, und die Ansagen hätten keinen Vorrang |
| PipeWire + WirePlumber | Nein. Deutlich mehr Speicher und Prozesse, und es will die Soundkarte selbst besitzen |

Das Backend spielt heute allen Ton selbst: Ein Mixer mit bis zu 8 Quellen (auch gestreamt über einen Ringpuffer) gibt auf **einen** ALSA-Ausgang aus.
Die Handy-Musik wird dort **eine weitere gestreamte Quelle**, wie ein Titel aus der eigenen Bibliothek.

**Debian trixie (bluez-alsa 4.3.1):**
- `bluez-alsa-utils` enthält den Dienst `bluealsa`, `bluealsa-cli` und `bluealsa-aplay` samt Unit. `libasound2-plugin-bluez` enthält das ALSA-Gerät `bluealsa`.
- Codecs: **SBC** (kann jedes Handy), dazu aptX, aptX HD, LDAC, FastStream, Opus. **Kein AAC** (fdk-aac liegt in non-free), iPhones nehmen dann SBC.
- Ohne weitere Einstellung meldet bluealsa als Sink nur SBC an. Für den Anfang reicht das.
- `bluealsa-aplay.service` wird mitinstalliert und muss **maskiert** werden, sonst greift er nach der Soundkarte.

## Ablauf für den Fahrer

1. Einstellungen → Bluetooth → **„Handy koppeln“**. CarNine ist jetzt **2 Minuten** sichtbar und koppelbar (Countdown), vorher und nachher nicht.
2. Am Handy unter Bluetooth „carnine“ wählen.
3. **Handy und Autobildschirm zeigen denselben 6-stelligen Code.** Der Fahrer tippt am Autobildschirm auf **„Code stimmt“** und bestätigt am Handy.
4. Der Bildschirm zeigt „Gekoppelt: <Name des Handys>“, das Fenster schließt sich.
5. Beim nächsten Einsteigen verbindet sich das Handy von selbst. Das Backend versucht es beim Start zusätzlich mit dem zuletzt verbundenen Handy.
6. Spielt das Handy, zeigt die Medien-Seite die Quelle **„Handy“** mit Titel, Interpret und Album sowie Play/Pause/Weiter/Zurück.

## Koppeln und Sicherheit

Klassisches Bluetooth kennt mit einem Handy nur den **Codevergleich** (das Handy meldet sich als „Anzeige mit Ja/Nein“). Mit Secure Connections schützt er gegen Mithören und Dazwischengehen, solange am Bildschirm wirklich verglichen wird.

| Regel | Warum |
|---|---|
| Koppelbar und sichtbar **nur nach Tippen am Autobildschirm**, 2 Minuten | Niemand auf dem Parkplatz kann sich koppeln, solange keiner im Auto sitzt |
| **Codevergleich, am Autobildschirm bestätigt.** Just Works (ohne Code) lehnt der Agent ab | Nur wer im Auto sitzt, kann ein Handy zulassen |
| **Keine feste PIN** (Legacy Pairing bleibt aus) | Eine feste PIN wäre deutlich schwächer |
| `SecureConnections = only` | Im Vorab-Test geprüft: Der Pi-4-Chip legt im klassischen Modus einen Schlüssel vom Typ 8 an (Secure Connections mit Schutz gegen Dazwischengehen) |
| Gekoppelte Handys sind vertraut (`Trusted`), höchstens **5**, jedes einzeln entfernbar | Wie im BLE-Plan |
| Ein gekoppeltes Handy darf **nur** A2DP-Ton senden und AVRCP sprechen. Kein Telefonbuch, keine Dateien (OBEX), kein Netz (PAN), kein SIM Access | Ab Werk bietet bluez „SIM Access“ an, das Plugin `sap` wird abgeschaltet |
| Bluetooth abschaltbar (`[bluetooth] enabled`), **Vorgabe aus** | Wer es nicht will, hat keinen Funk an |

**Ein Agent für alles.** Das Backend registriert genau einen Agent bei BlueZ (Fähigkeit **DisplayYesNo**). Er gilt für das Koppeln für Musik und für die BLE-App.
Mit DisplayYesNo wird auch BLE mit Secure Connections zum Codevergleich: ein Knopf, ein Dialog, für beides. Im Vorab-Test hat eine klassische Kopplung auch gleich die BLE-Schlüssel angelegt.

## Navigationsansagen haben Vorrang

Eine Ansage senkt die Musik im Mixer auf `[voice] music_under_percent` (Vorgabe 30 %), mit Blende, bei vier Boxen nur vorn. Für die Handy-Quelle gilt **dasselbe ohne neue Logik**.

- **Bei `music_under_percent = 0`** hält die eigene Musik heute an. Einen Strom vom Handy kann der Mixer nicht anhalten. Deshalb schickt das Backend für die Quelle „Handy“ bei 0 **AVRCP Pause vor der Ansage und Play danach**. Antwortet das Handy nicht, bleibt die Quelle für die Ansage stumm.
- Hat der Fahrer während der Ansage selbst am Handy pausiert, kommt danach **kein** Play (das Backend merkt sich, ob die Pause von ihm kam).

## Eigene Musik und Handy-Musik

Es spielt immer nur eine Quelle, **die zuletzt gestartete gewinnt**:
- Beginnt das Handy zu spielen, pausiert die eigene Musik (die Stelle im Titel bleibt).
- Tippt der Fahrer bei der eigenen Musik auf Play, geht AVRCP Pause ans Handy.
- **Hört das Handy auf** (Pause, Trennen, Aussteigen, Akku leer), läuft die eigene Musik **nicht** von selbst weiter. Die Medien-Seite springt auf die eigene Musik zurück, mit Play an der alten Stelle; ein Tipp genügt.
  Pause am Handy heißt meist „Ruhe“ (Telefonat, Gespräch), und beim Aussteigen soll das Auto nicht weiterspielen.

**Verhältnis zur BLE-App:** Gleicher Chip, gleicher Agent, gleiche Liste gekoppelter Handys. Die App steuert die eigene Musik, AVRCP die Handy-Musik.

## WLAN über USB-Stick

- **Warum:** WLAN und Bluetooth teilen sich auf dem Pi 4 einen Chip und eine Antenne. A2DP braucht dauernd 2,4 GHz.
- **Image:** `dtoverlay=disable-wifi` im Abschnitt `[pi4]` der `config.txt`. Bluetooth bleibt am Standard-UART (das Netzteil-Modul hängt an uart5).
- **Stick:** Realtek **RTL8822BU** (USB 0bda:b812, Treiber `rtw88_8822bu` aus dem Kernel, Firmware aus **`firmware-realtek`**, meldet 504 mA an).
- **Ergebnis Vorab-Test:**
  - **5 GHz: gut.** 95 Mbit/s über 5 Minuten neben Musik vom Handy, ohne Lücke im Bluetooth-Ton.
  - **2,4 GHz: untauglich.** Der Stick meldet sich an und bekommt per DHCP eine Adresse, sendet danach aber nichts mehr (Kernel: „failed to get tx report from firmware“). Am Zugangspunkt geprüft, in zwei Netzen, mit und ohne Bluetooth, mit und ohne Energiesparen.
  - **Strom:** Direkt am Pi (dort hingen zusammen etwa 1,2 A an den USB-Ports) fiel der Stick einmal vom USB ab, an einem Hub mit eigenem Netzteil nicht.
- **Entscheidung:** Kein anderer Stick. Der RTL8822BU kommt **an den Hub**, nicht direkt an den Pi, und **der Handy-Hotspot läuft auf 5 GHz**.
- **5 GHz erzwingen:** `carnine-wlan --band 5` bzw. Vorgabe `BAND=5` in `/etc/carnine/wlan.conf` (im Auto-Image gesetzt) schreibt `freq_list=` mit allen 5-GHz-Frequenzen (5170–5885 MHz) in den Netzblock von wpa_supplicant. `--band any` bleibt für das Heimnetz.
  Die Scan-Liste zeigt das Band; ist ein Netz nur auf 2,4 GHz zu sehen, sagt `carnine-wlan` deutlich: „Hotspot am Handy auf 5 GHz stellen“. Tests in `resources/debos/tests/carnine-wlan-test.sh`.
- **Anleitung (wenn gebaut):** Hotspot am Handy auf 5 GHz stellen. Bei Samsung: Mobiler Hotspot → Band 5 GHz, „WLAN-Freigabe“ aus, automatisches Abschalten „Nie“ (sonst schaltet das Handy den Hotspot nach einigen Minuten ohne Gerät ab).
- Der Stick heißt `wlan1` bzw. `wlx<MAC>`; `carnine-wlan` und `wireless.network` (`Name=wl* wlan*`) passen dafür schon.

## Was ins Image muss (carnine2)

| Teil | Inhalt |
|---|---|
| Pakete | `bluez-alsa-utils`, `libasound2-plugin-bluez`, `firmware-realtek` |
| `bluealsa` | Drop-in: nur `-p a2dp-sink` (kein a2dp-source, kein HFP/HSP) |
| `bluealsa-aplay.service` | maskiert |
| `/etc/bluetooth/main.conf` | `ControllerMode = dual`, `SecureConnections = only`, `JustWorksRepairing = never`, `Privacy = device`, `AlwaysPairable = false`, `DiscoverableTimeout` nicht 0, `Name = carnine`, `Class = 0x240420` (Audio/Video „Car audio“, damit Handys es als Auto zeigen) |
| bluetoothd | Plugin `sap` aus (`--noplugin=sap`) |
| rfkill | Bluetooth beim Start entsperren, WLAN bleibt gesperrt, bis `carnine-wlan` es braucht |
| config.txt | `[pi4]` `dtoverlay=disable-wifi` |
| `carnine-wlan` | `--band 5` / `BAND=5` (siehe oben) |
| Rechte | Der Benutzer `carnine` ist schon in der Gruppe `audio` (Image und `SupplementaryGroups=audio`). Damit darf er das `bluealsa`-Gerät ohne root öffnen (im Vorab-Test bestätigt) |
| Prüfung beim Bau | wie bisher per debugfs: Pakete, Drop-in, Maske, config.txt-Zeile, main.conf |

## Was ins Backend muss (carnine2, Rust)

| Teil | Aufgabe |
|---|---|
| **Bluetooth-Modul** (zbus) | Adapter, Koppelfenster, **ein** Agent (DisplayYesNo): `RequestConfirmation` gibt den Code an die UI und wartet auf „Code stimmt“/„Abbrechen“ (Zeitlimit = Fenster). Just Works, `RequestPinCode` und fremde Profile ablehnen. Geräteliste, Entfernen, Grenze 5. Beim Start Wiederverbinden mit dem letzten Handy |
| **Ton-Quelle „Handy“** | Wenn bluealsa ein A2DP-PCM meldet (D-Bus `org.bluealsa`, `PCMAdded`), das Gerät per **ALSA-Capture** lesen (alsa-Crate; cpal kann den Gerätenamen nicht öffnen), auf die Mixer-Rate wandeln und als gestreamte Quelle in den Mixer geben. Bei `PCMRemoved` oder Abriss leise schließen |
| **Puffer und Takt** | Der Ton kommt in Schüben von etwa 130–145 ms. **Puffer einstellbar** (`[bluetooth] buffer_ms`, Vorgabe 500 ms, etwa 100–1500). Taktausgleich über den Füllstand, träge (über Sekunden gemittelt). Nur ganze Frames in den Puffer. Läuft der Puffer leer: in etwa 10 ms ausblenden, erst bei halber Puffergröße wieder einblenden. Der Mixer wartet nie auf die Quelle. Log: fehlende Zeit pro Minute, längste Lücke |
| **Pegel** | Beim Verbinden die Handy-Lautstärke auf 100 % (`MediaTransport1.Volume`). Dann `[bluetooth] phone_gain_db` (Vorgabe etwa +10 dB, am Gerät einstellen; im Hörtest war das Handy vor dem Lautstärkeregler gleich laut wie die eigene Musik dahinter). Über 0 dB ein weicher Begrenzer nur für diese Quelle |
| **AVRCP** | `org.bluez.MediaPlayer1`: `Play`/`Pause`/`Next`/`Previous`, `Track` (Titel, Interpret, Album, Dauer), `Status`, `Position`. An die UI wie der eigene Player |
| **Quellen-Regel** | „Zuletzt gestartet gewinnt“, kein Fortsetzen von selbst (siehe oben) |
| **gRPC** | `BluetoothService` aus dem BLE-Plan, mit Ereignis `CONFIRM_PASSKEY` (Code) und Antwort `ConfirmPairing(bool)`. Der Player-Status bekommt eine Quelle `PHONE` mit Gerätename |
| **Konfiguration** | `[bluetooth] enabled = false`, `name`, `pairing_window_seconds = 120`, `max_paired_devices = 5`, `a2dp = true`, `buffer_ms = 500`, `phone_gain_db` |
| **Robustheit** | Ohne Adapter oder bei Neustart von bluetoothd/bluealsa kein Absturz, Ereignis `ADAPTER_UNAVAILABLE`, neu anmelden. Um jeden BlueZ-Aufruf ein eigenes Zeitlimit |

**Tests:**
- Unit-Tests ohne Funk, mit D-Bus hinter einem Trait: Agent (Code → Ereignis, bestätigt → angenommen, Zeitablauf/Nein → abgelehnt, Just Works → abgelehnt), Quellen-Regel, Ansage bei 0 % → Pause/Play und bei 30 % → Absenken, Puffer (Lücke 0,6 s bei 500 ms → eine Pause mit Blende; Schübe unter der Puffergröße → keine Pause), Begrenzer (Vollaussteuerung bei +10 dB bleibt unter 1,0).
- Gerätetest auf dem Test-Pi: Koppeln, Ton, Ansage über Handy-Musik, Knöpfe und Titel, Aus- und Einsteigen, Neustart von bluetoothd, WLAN-Stick unter Last, 4-Boxen- und AC-3-Ausgang. Dazu: Handy als Hotspot **und** Musikquelle gleichzeitig, und dasselbe mit Hotspot aus und mobilen Daten an (siehe Befund unten), möglichst auch mit einem zweiten Handy und einem iPhone (SBC).

## Was in die Oberfläche muss (Frontend, Ticket)

| Teil | Inhalt |
|---|---|
| Einstellungen → **„Bluetooth“** | Schalter an/aus, **„Handy koppeln“**, Liste der gekoppelten Handys mit „Entfernen“ (Rückfrage). Ersetzt den Bereich „Handy-App“ aus dem BLE-Plan und deckt beides ab |
| **Koppel-Dialog** | Countdown 2:00. Bei `CONFIRM_PASSKEY` den **Code sehr groß** (`530 525`), „Zeigt das Handy denselben Code?“, Knöpfe **„Code stimmt“** und „Abbrechen“. Danach „Gekoppelt: …“ oder „Fehlgeschlagen, noch einmal?“ |
| **Medien-Seite** | Quelle „Handy (<Name>)“: Titel, Interpret, Album, Play/Pause/Weiter/Zurück, Fortschritt, wenn das Handy ihn meldet. Ohne Cover ein Bluetooth-Symbol. Kein Durchsuchen der Handy-Bibliothek |
| Kopfleiste | kleines Symbol, solange ein Handy verbunden ist |
| Texte, Tests | alle Texte in den 15 Sprachen. Widget-Tests mit nachgebildetem `BluetoothService` |

## Vorab-Test auf dem Test-Pi (23.11.2026)

Pi 4, Debian trixie, bluez 5.82, bluez-alsa 4.3.1, Android-Handy (Samsung). CarNine lief die ganze Zeit unverändert weiter.

| Prüfung | Ergebnis |
|---|---|
| Koppeln | Codevergleich, gleicher Code auf beiden Seiten. Schlüssel Typ 8 (Secure Connections) |
| A2DP | SBC, 44,1 kHz. Mitschnitt über das ALSA-Gerät `bluealsa` mit Wandlung auf 48 kHz, als normaler Benutzer (Gruppe `audio`) |
| AVRCP | Titel, Album, Interpret, Dauer, Position kommen an. Pause und Play aus der Ferne wirken |
| Last | bluealsa 9,7 MB, etwa 1 % eines Kerns. bluetoothd 6,5 MB |
| Gleichmäßigkeit | Der Ton kommt vollständig, aber in Schüben alle 130–145 ms. Ein Mischen, das auf die Quelle wartet, setzt aus; mit Puffer und Zeitstempeln nach Wanduhr nicht mehr. Hörtest über vier Boxen ohne Unterbrechung |
| Pegel | Handy (Lautstärke 77 %) bei −12 dB etwa so laut wie die eigene Musik bei 55 % hinter dem Regler (−22,8 dB) |
| WLAN 5 GHz + Musik | 95 Mbit/s über 5 min, keine Lücke im Bluetooth-Ton, keine Unterspannung |
| WLAN 2,4 GHz | Stick untauglich (siehe oben) |
| Hotspot + Musik vom **selben** Handy (5 GHz) | WLAN gut, aber **1,64 s Ton fehlen in 5 min**, Lücken bis 575 ms. Ohne Hotspot keine Lücken. Vermutlich kommt das Handy mit beidem gleichzeitig nicht ganz nach; deshalb der größere, einstellbare Puffer |

Ein Fallstrick für Tests: Hängt ein Pi mit Kabel und WLAN im selben Netz, antwortet er ab Werk auf beiden Schnittstellen für beide Adressen (ARP-Flux). Für saubere Tests vorübergehend `arp_ignore=1` und `arp_announce=2` setzen. Im Auto gibt es kein zweites Netz.

## Reihenfolge

1. ~~Vorab-Test auf dem Test-Pi~~ (bestanden, 23.11.2026).
2. **Image:** Pakete, Drop-ins, main.conf, Overlay, `carnine-wlan --band 5`, Prüfung beim Bau.
3. **Backend Teil 1:** Bluetooth-Modul mit Agent und Koppelfenster.
4. **Backend Teil 2:** Ton-Quelle „Handy“ mit Puffer, Taktausgleich, Pegel, Quellen-Regel.
5. **Backend Teil 3:** AVRCP und gRPC.
6. **Oberfläche:** Einstellungen, Dialog, Medien-Seite (ab dem fertigen gRPC-Teil parallel). Danach Bilder für die Anleitung und SD-Test wie bei jeder Version.

**Aufwand (Schätzung carnine2):** Image 1 Tag, Backend 3–4 + 3 + 2 Tage, Gerätetests 1–2 Tage, **zusammen 9–12 Arbeitstage**. Dazu die Oberfläche.

## Entscheidungen (23.11.2026)

| | Frage | Antwort |
|---|---|---|
| A | Ansage über Handy-Musik | Wie bei der eigenen Musik (`music_under_percent`); bei 0 AVRCP Pause/Play |
| B | Ein Koppel-Dialog mit Codevergleich, auch für die BLE-App | Ja (BLE-Plan ist nachgezogen) |
| C | Eigene Musik und Handy | Zuletzt gestartet gewinnt. Hört das Handy auf, läuft die eigene Musik nicht von selbst weiter |
| D | WLAN-Stick | Kein anderer Stick. RTL8822BU am Hub, Handy-Hotspot auf 5 GHz |
| E | USB-Anschlüsse | **Offen.** Richtung Hub an einem eigenen, geschalteten 5-V-Ausgang (1 A abgesichert). Ob 1 A reicht, klärt eine Strommessung. Kamera und Grabber bleiben direkt am Pi |
| F | Telefonieren (HFP) | Eingeplant als eigener Schritt nach A2DP, zusammen mit Mikrofon und Audio-Manager, ohne Datum |
| G | Wann | Vorab-Test erledigt, Bauen ab 0.25.0, Musik vom Handy vor der BLE-App |

## Telefonieren (HFP) – eigener Schritt danach

Eingeplant (23.11.2026) nach Musik vom Handy, ohne Datum. Angefangen ist nichts.

Mikrofon und Echounterdrückung sind in ADR-024 (carnine2, docs/09) schon entschieden. Hier steht nur, was für HFP dazukommt.
- CarNine ist die Freisprecheinrichtung (HFP „Hands-Free“). Ton geht in beide Richtungen, dazu Klingeln, Nummer, Annehmen, Auflegen.
- bluez-alsa `-p hfp-hf` für den Gesprächston (mSBC, sonst CVSD 8 kHz), oFono für die Rufsteuerung (in trixie noch zu prüfen).
- Beim Pi-Chip läuft der Gesprächston (SCO) ab Werk auf die PCM-Pins, nicht über HCI. Raspberry Pi OS stellt das mit `bthelper` um. Erste Prüfung: Kommt SCO-Ton über HCI an?
- Mikrofon: das USB-Mikrofon aus ADR-024, dasselbe wie für die Spracheingabe.
- Echo: WebRTC-Echo-Canceller als Bibliothek im Backend, die eigene Ausgabe als Referenz. Das ist der aufwendigste Teil.
- Während eines Anrufs pausiert jede Musik. Ansagen nur leise auf die Boxen, nie ins Gespräch. Kein Telefonbuch (PBAP), zuerst nur Nummern.
- Aufwand (Schätzung carnine2): 13–19 Arbeitstage für Image und Backend, unsicherer als A2DP.

## Verlauf

- 23.11.2026: Entwurf, Antworten A–G, Vorab-Test (Koppeln, A2DP, AVRCP, Hörtest, WLAN-Stick, Hotspot), Fassung 4b ins Repo übernommen.
