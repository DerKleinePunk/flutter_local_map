# Entwurf: Handy-App über Bluetooth Low Energy, Kopplung mit Code am Handy

Von: flutter-local-map, 30.09.2026, Fassung 2 (Michaels Antworten von 10:32–11:24 eingearbeitet; Fassung 1 im Verlauf am Ende)
Ablage: `flutter_local_map/docs/plan-ble-kopplung.md` (verbindlich), Kopie auf dem Share als `entwurf-ble-kopplung.md`
Für: Michael, carnine2 (Backend/UI/Image), carnine2-docs
Anlass: 2026-09-30_1023_michael_ble-konzept.md

Stand von carnine2: v0.9.3 (cae5fbb). Grundlage ist der Kopplungstest auf jeep-pi vom 30.09. (klassisches Bluetooth, Codevergleich).
Das hier ist ein Konzept. Gebaut ist davon nichts, eine App gibt es noch nicht.

## Das Ziel in einem Satz

Der Fahrer tippt am Autobildschirm auf „Handy koppeln“. Der Bildschirm zeigt einen 6-stelligen Code, den er am Handy eintippt.
Danach kann die carnine-App auf dem Handy **Musik und Lautstärke** steuern, ohne dass jemand anderes das kann.

## Warum BLE und nicht klassisches Bluetooth

- Beim klassischen Bluetooth meldet sich ein Handy immer als „Anzeige mit Ja/Nein“. Dann gibt es nur „Codes vergleichen“ (heute getestet), kein Eintippen.
- Bei **BLE** meldet sich ein Android-Handy als „Tastatur und Anzeige“. Meldet sich der Pi als **„nur Anzeige“**, schreibt die Spezifikation **„Passkey Entry“** vor:
  Der Pi erzeugt einen zufälligen 6-stelligen Code und zeigt ihn an, und am Handy wird er eingetippt. Mit **LE Secure Connections** ist das gegen Mithören und Dazwischengehen geschützt.
- Eine App braucht ohnehin kein Profil für Ton oder Telefon, sondern einen eigenen kleinen Datenkanal. Das ist bei BLE ein **GATT-Dienst**. Flutter kann das auf Android gut (`flutter_blue_plus`).

## Ablauf für den Fahrer

1. Einstellungen → „Handy-App“ → **„Handy koppeln“**. Der Pi ist jetzt **2 Minuten** koppelbar (Countdown auf dem Bildschirm), vorher und nachher nicht.
2. In der App auf dem Handy: „Mit Auto verbinden“. Die App findet „carnine“ und verbindet sich.
3. Android fragt: „Code eingeben“. **Der Autobildschirm zeigt den Code groß an.** Der Fahrer tippt ihn ein.
4. Der Bildschirm zeigt „Gekoppelt: A55 von Michael“. Das Fenster schließt sich, und der Pi ist nicht mehr koppelbar.
5. Beim nächsten Einsteigen verbindet sich die App von selbst, ohne Code.
6. Einstellungen zeigt die **gekoppelten Handys** mit „Entfernen“.

Falscher Code, abgelaufene Zeit oder Abbruch am Handy: Die UI zeigt „Kopplung fehlgeschlagen“, und man kann es noch einmal versuchen.

## Sicherheit (die Regeln)

| Regel | Warum |
|---|---|
| Koppelbar **nur nach Tippen am Autobildschirm**, 2 Minuten | Niemand auf dem Parkplatz kann sich koppeln, solange keiner im Auto sitzt |
| **Nur Passkey Entry mit LE Secure Connections**, kein Just Works, kein Legacy | Ohne den Code vom Bildschirm keine Kopplung, und mitschneiden bringt nichts |
| Alle GATT-Kennwerte außer der Kennung verlangen **„verschlüsselt mit Authentifizierung“** | Ein Gerät, das nur „Just Works“ gekoppelt hat, darf nichts lesen und nichts schreiben |
| Höchstens **5 gekoppelte Handys**, jedes einzeln entfernbar | Übersicht, verlorenes Handy austragen |
| Die App darf **nur Musik und Lautstärke** (feste Liste unten). Die Befehle gehen durch **dieselbe Prüfung wie die UI-Befehle** | Die App kann weniger als der Bildschirm. Navigation, Einstellungen, Beenden und Updates gehen nicht über BLE |
| **Klassisches Bluetooth bleibt an** (`ControllerMode = dual`, Michael 10:32) | Damit bleibt später Musik vom Handy übers Auto (A2DP) möglich. Die Regeln oben gelten für beide: außerhalb des Koppelfensters nicht koppelbar, und klassisches Koppeln mit Codevergleich oder Just Works lehnt der Agent ab. Klassisch koppelt also vorerst niemand |
| Bluetooth über Konfiguration abschaltbar (`[bluetooth] enabled`), **Vorgabe aus** | Wer keine App will, hat kein Funkmodul an |

## Was ins Backend muss (carnine2, Rust)

Neues Modul `bluetooth/`. Das Backend hat `zbus` schon (udisks2), bluez spricht man genauso über D-Bus an. Eine neue Kiste (Crate) braucht es nicht.

| Teil | Aufgabe |
|---|---|
| **Adapter** (`org.bluez.Adapter1`) | beim Start einschalten, Name setzen („carnine“ bzw. Hostname), **Pairable nur im Koppelfenster** (`PairableTimeout` 120 s) |
| **Werbung** (`LEAdvertisingManager1`) | Kennung (UUID) des carnine-Dienstes und Name bekanntgeben, damit die App das Auto findet. Immer, wenn Bluetooth an ist, damit gekoppelte Handys wiederfinden |
| **Agent** (`Agent1`, Fähigkeit **DisplayOnly**) | `DisplayPasskey` → Ereignis mit dem Code an die UI. `Cancel` → Ereignis „fehlgeschlagen“. `RequestConfirmation`/`RequestAuthorization` (Just Works) → **ablehnen**. Nur im Koppelfenster registriert |
| **GATT-Dienst** (`GattManager1`) | Eine eigene Dienst-UUID mit drei Kennwerten: **Info** (lesen: Version, Name; ohne Kopplung), **Befehl** (schreiben, verschlüsselt+authentifiziert), **Status** (melden/notify, verschlüsselt+authentifiziert: Titel, Lautstärke) |
| **Nachrichtenformat** | **protobuf**, dieselben Nachrichten wie in `carnine.proto` (z. B. `PlayRequest`, `SetVolumeRequest`) in einer Hülle `BleCommand { oneof … }` mit fortlaufender Nummer. Antwort als `CommandResponse` über Status. Größe ≤ ausgehandelte MTU, längere Antworten gestückelt |
| **Befehle ausführen** | Die Hülle auspacken und **dieselben internen Funktionen** aufrufen, die die gRPC-Methoden nutzen. **Erlaubt sind nur:** `Play`, `Pause`, `Next`, `Previous`, `Seek`, `PlayPlaylist`, `ListPlaylists`, `GetPlayerState`, `GetVolume`, `SetVolume`. Alles andere wird mit Fehler abgelehnt |
| **Status melden** | Player-Ereignisse (Titel, Interpret, Position, Play/Pause) und Lautstärke-Ereignisse an verbundene, gekoppelte Handys |
| **Geräteverwaltung** | gekoppelte Handys auflisten (`Device1`, Paired/Bonded), entfernen (`Adapter1.RemoveDevice`), Grenze 5 |
| **gRPC für die UI** | neuer Dienst `BluetoothService`: `GetBluetoothStatus`, `StreamBluetoothEvents`, `StartPairing`, `CancelPairing`, `ListPairedDevices`, `RemovePairedDevice` |
| **Ereignisse** | `BluetoothEvent`: `PAIRING_WINDOW_OPENED` (Sekunden), `PASSKEY` (Code), `PAIRED` (Gerätename), `PAIRING_FAILED` (Grund), `PAIRING_WINDOW_CLOSED`, `DEVICE_CONNECTED/DISCONNECTED`, `ADAPTER_UNAVAILABLE` |
| **Konfiguration** | `[bluetooth] enabled = false`, `name`, `pairing_window_seconds = 120`, `max_paired_devices = 5` |
| **Robustheit** | Fehlt der Adapter oder startet bluetoothd neu: kein Absturz, `ADAPTER_UNAVAILABLE`, bei `InterfacesAdded` neu registrieren (wie `RetryingAudioEngine`) |

**Tests** („unser Gold“):
- Unit-Tests ohne Funk: die Zustandsmaschine Koppelfenster/Agent (Code → Ereignis, Just Works → abgelehnt, Zeitablauf → geschlossen), Hülle auspacken und erlaubte Befehle, Grenze 5 und Stückeln.
  Dazu wird D-Bus hinter ein Trait gelegt, wie bei der Audio-Engine.
- Gerätetest auf jeep-pi mit **nRF Connect** (App von Nordic): Werbung sichtbar, Info ohne Kopplung lesbar, Befehl ohne Kopplung abgelehnt, Kopplung mit Code, Befehl danach geht, Entfernen, Neustart von bluetoothd.

## Was in die UI muss (carnine2 Frontend, Flutter)

| Teil | Inhalt |
|---|---|
| Einstellungen → **„Handy-App“** | Schalter „Bluetooth an/aus“ (schreibt `[bluetooth] enabled`), Knopf **„Handy koppeln“**, Liste der gekoppelten Handys mit „Entfernen“ (mit Rückfrage) |
| **Koppel-Dialog** | Countdown 2:00 → 0:00, Hinweis „In der carnine-App auf ‚Mit Auto verbinden‘ tippen“. Kommt `PASSKEY`: **Code riesig** (z. B. `530 525`, gut lesbar im Auto), darunter „Diesen Code am Handy eingeben“. Danach „Gekoppelt: …“ oder „Fehlgeschlagen, noch einmal?“. Abbrechen schließt das Fenster |
| Top-Bar (klein) | Symbol „Handy verbunden“, wenn eine App verbunden ist |
| Texte | alle neuen Texte in den 15 Sprachen |
| Tests | Widget-Tests für den Dialog (Countdown, Code-Anzeige, Erfolg, Fehler) mit einem nachgebildeten `BluetoothService` |

## Was ins Image muss (debos-Rezept)

Vorhanden sind schon `bluez`, `bluez-firmware` und `rfkill`. Dazu kommt:

| Teil | Inhalt |
|---|---|
| **rfkill** | Bluetooth beim Start entsperren, **WLAN gesperrt lassen**. Das Raspberry-Pi-OS sperrt beides ab Werk, jeep-pi war „off-blocked“. Das Backend schaltet den Adapter dann nur noch ein/aus |
| `/etc/bluetooth/main.conf` (Ausschnitt) | `ControllerMode = dual` (so bleibt es, Michael 10:32), `SecureConnections = only`, `JustWorksRepairing = never`, `Privacy = device`, `Name = carnine`, `AlwaysPairable = false` |
| Rechte | bluez erlaubt Nachrichten an `org.bluez` jedem, die Rückrufe an Agent und GATT gehen von root aus (so in `bluetooth.conf`). Der Benutzer `carnine` braucht deshalb **keine eigene D-Bus-Regel**, das wird im Test bestätigt |
| Unit | `carnine-backend.service`: `After=bluetooth.service` und `Wants=bluetooth.service` (kein Requires: ohne Bluetooth muss das Backend trotzdem laufen) |
| Konfiguration | `[bluetooth] enabled = false` in der ausgelieferten `config.toml` |
| Prüfung beim Bau | im Rootfs nachsehen: main.conf-Werte, Unit-Abhängigkeit (wie heute bei EDID/Audio per debugfs) |

## Die App (später, nur zur Einordnung)

Flutter/Android mit `flutter_blue_plus`. Sie sucht nach der carnine-Dienst-UUID, verbindet sich und liest Info. Beim ersten Schreiben auf „Befehl“ löst Android selbst die Kopplung aus, mit dem Dialog „Code eingeben“.
Dieselben `.proto`-Dateien wie das Frontend, also gleiche Nachrichten. Sie hat eine Seite: aktueller Titel, Play/Pause/Weiter/Zurück, Playlists, Lautstärke. Mehr darf sie nicht (Michael 10:32).

## Reihenfolge (Vorschlag, je Schritt einzeln prüfbar)

1. **Image:** rfkill und main.conf. Auf jeep-pi von Hand vorab prüfen (ich), dann ins Rezept (carnine2).
2. **Backend Teil 1:** Adapter, Werbung, Info-Kennwert, `BluetoothService` Status. Test mit nRF Connect: „carnine“ sichtbar, Info lesbar.
3. **Backend Teil 2:** Agent, Koppelfenster, Ereignisse, Geräteverwaltung. Test: Kopplung mit Code, dabei den Code von Hand aus dem Log.
4. **UI:** Einstellungen und Koppel-Dialog. Test: Code auf dem Bildschirm, Kopplung, Entfernen.
5. **Backend Teil 3:** Befehl/Status mit protobuf-Hülle und erlaubten Befehlen. Test: Play/Pause und Lautstärke über nRF Connect (Bytes von Hand), ein nicht erlaubter Befehl wird abgelehnt.
6. **App:** erst jetzt, wenn Michael es will.

Schritte 1–5 sind geschätzt **3–5 Tage** zusammen, je nach Test auf dem Gerät.

## Entscheidungen (Michael, 30.09. 10:32)

| Frage | Antwort |
|---|---|
| Klassisches Bluetooth ganz aus? | **Nein.** `ControllerMode = dual` bleibt, A2DP später möglich |
| Welche Befehle darf die App? | **Nur Musik und Lautstärke** (Liste oben unter „Befehle ausführen“) |
| 5 Handys, Koppelfenster 2 Minuten? | **Passt** |
| Wer baut was? | **Image und Backend: carnine2** (Aufwand laut carnine2: 4–6 Tage ohne UI, 1033). **UI: als Ticket, macht Jonas** |
| Klassisches Koppeln (bis es A2DP gibt)? | **Vorerst abgelehnt**, mit eigenem Test (Michael 11:23) |
| Zielgerät? | **Nur der Pi 4.** Getestet und freigegeben wird für den Pi 4, der Pi 3 (carnine-pc zurzeit) ist nur die Notlösung zum Arbeiten (Michael 11:24). Damit ist carnine2s Frage erledigt, ob „Secure Connections only“ auf dem Pi 3 geht |
| Tickets? | **Zwei Tickets:** „BLE: Image + Backend“ (carnine2) und „BLE: UI“ (Jonas), angelegt von carnine2 (Michael 11:24) |
| Wann? | **Nicht vor der Messe (6.11.2026).** Die Tickets bleiben angelegt, angefangen wird erst danach (Michael 13:40) |

## Vorlage für das UI-Ticket (für Jonas)

**Titel:** Einstellungen „Handy-App“: Bluetooth-Kopplung mit Code (BLE)

**Hintergrund:** Das Backend bekommt einen `BluetoothService` (gRPC, siehe Entwurf). Die UI zeigt den Code, den der Fahrer am Handy eintippt.

**Aufgaben:**
- Einstellungen → neuer Bereich „Handy-App“: Schalter Bluetooth an/aus, Knopf „Handy koppeln“, Liste gekoppelter Handys mit „Entfernen“ (Rückfrage).
- Koppel-Dialog: Countdown ab `PAIRING_WINDOW_OPENED`, Hinweis „In der carnine-App auf ‚Mit Auto verbinden‘ tippen“. Bei `PASSKEY` den Code sehr groß in zwei Dreiergruppen und „Diesen Code am Handy eingeben“.
  Danach bei `PAIRED` „Gekoppelt: <Name>“, bei `PAIRING_FAILED` „Fehlgeschlagen, noch einmal?“. Abbrechen ruft `CancelPairing`.
- Top-Bar: kleines Symbol, solange ein Handy verbunden ist (`DEVICE_CONNECTED`/`DISCONNECTED`).
- `ADAPTER_UNAVAILABLE`: Bereich ausgegraut mit Hinweis.
- Alle Texte in 15 Sprachen.
- Widget-Tests mit nachgebildetem `BluetoothService`: Countdown, Code, Erfolg, Fehler, Abbrechen, Entfernen.

**Abhängig von:** Backend Schritt 2–3 (Ereignisse, `BluetoothService`). Bis dahin reicht die Nachbildung.

## Verlauf

- Fassung 1 (10:25): mit vier offenen Fragen, darunter der Vorschlag `ControllerMode = le` und Befehle auch für die Navigation.
- Fassung 2 (10:33): Michaels Antworten. `dual` statt `le`, nur Musik und Lautstärke, dazu die Vorlage fürs UI-Ticket.

### Offene Fragen aus Fassung 1 (beantwortet)

1. **Klassisches Bluetooth ganz aus** (`ControllerMode = le`)? Oder soll später Musik vom Handy übers Auto laufen (A2DP)? Das wäre eine eigene, größere Aufgabe.
2. **Welche Befehle** soll die App dürfen? Vorschlag: Musik (Play/Pause/Weiter/Zurück, Playlist), Lautstärke, Ziel suchen und Route starten. Nicht: Einstellungen, Beenden, Update.
3. **Grenze 5 Handys**, Koppelfenster 2 Minuten: passt das?
4. **Wer baut was:** Image, Backend und UI gehören carnine2. Den Vorab-Test auf jeep-pi (Schritt 1) und die Gerätetests kann ich machen.
