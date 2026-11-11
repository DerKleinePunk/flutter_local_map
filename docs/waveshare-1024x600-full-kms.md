# Waveshare 7" HDMI LCD (H) mit 1024x600 unter Full-KMS

**Ergebnis:** Das Panel laeuft mit `dtoverlay=vc4-kms-v3d` nativ in 1024x600.
`vc4-fkms-v3d` und die `hdmi_cvt`-Zeilen werden nicht gebraucht. Verifiziert am
2026-09-22 auf dem Test-Pi (Pi 4 Model B, Debian 13, Kernel 6.18).

Das ist wichtig, weil ivi-homescreen mit dem Backend `drm-kms-egl` auf Atomic
Modeset, Overlay- und Cursor-Plane und Explicit Sync aufsetzt. Firmware-KMS
liefert das nicht im selben Umfang.

## Warum es ohne Eingriff nicht geht

Das Panel bringt ein **geklontes EDID** mit. Es gibt sich als Lenovo-Monitor
aus - Herstellerkuerzel `LEN`, Name `LEN L1950wD`, Baujahr 2011, Bildflaeche
41 x 26 cm (das waeren 19 Zoll), Seriennummer `0x01010101`. Nur der erste
Detailtiming-Block wurde vom Hersteller ersetzt und traegt die echten Werte:

```
1024x600, Pixeltakt 49000 kHz
h: aktiv 1024, front 5, sync 13, total 1312
v: aktiv  600, front 2, sync  3, total  622
```

Daraus folgt `hsync_start = 1024 + 5 = 1029`, und das ist **ungerade**. Der
HDMI-Controller des Pi 4 (bcm2711) kann keine ungeraden horizontalen Timings;
im vc4-Treiber steht das als `unsupported_odd_h_timings`. Der Treiber verwirft
den bevorzugten Modus des Panels deshalb:

```
vc4-drm gpu: [drm] User-defined mode not supported:
"1024x600": 60 49000 1024 1029 1042 1312 600 602 605 622
```

`/sys/class/drm/card*-HDMI-A-1/modes` enthaelt dann **kein** 1024x600. Der
Treiber faellt auf die 1920x1080-Eintraege aus dem CEA-Erweiterungsblock des
geklonten EDIDs zurueck, das Panel bekommt 1920x1080 zugespielt und skaliert
selbst herunter. Man sieht ein Bild - aber ein weichgezeichnetes, und
Beschriftungen werden unleserlich klein.

Ein erzwungener Modus per `video=HDMI-A-1:1024x600M@60D` hilft nicht: der
Kernel baut denselben Modus und der Treiber lehnt ihn aus demselben Grund ab.
`MR` (Reduced Blanking) aendert daran nichts.

## Die Loesung: EDID mit geraden Timings unterschieben

Das EDID im Panel selbst laesst sich nur mit einem Hardware-Programmer
aendern (Auskunft Waveshare, 2026-09-29). Der Kernel bekommt deshalb per
`drm.edid_firmware` ein korrigiertes EDID aus einer Datei.

### Vorgabe: die Datei von Waveshare (seit 2026-09-29)

`edid/waveshare-7h-260929.bin` (256 Byte, sha256
`07ee8b8361264a829890d64b4a897964840b4c6ab678518e73b3ac65bbb73edd`) kam auf
Anfrage vom Hersteller. Es ist dasselbe geklonte EDID mit neuem erstem
Detailtiming und richtiger Bildgroesse:

```
1024x600, Pixeltakt 50250 kHz, 59,82 Hz
h: aktiv 1024, front 44, sync 88, total 1344   (alles gerade)
v: aktiv  600, front  3, sync  6, total  625
Bildgroesse 154 x 86 mm
```

Der CEA-Erweiterungsblock ist byte-gleich mit dem Original. Audio ueber HDMI
(LPCM, HDMI-VSDB) bleibt also erhalten. Verifiziert am 2026-09-29 auf dem
Test-Pi: 1024x600 @ 60 Hz nativ, Bild scharf, ELD mit Audio-Deskriptor,
`speaker-test` und Carnine2 spielen Ton.

Installation wie unten in Schritt 2 und 3, nur mit diesem Dateinamen:

```bash
sudo cp waveshare-7h-260929.bin /lib/firmware/edid/
# cmdline.txt: drm.edid_firmware=HDMI-A-1:edid/waveshare-7h-260929.bin
```

**Nicht verwenden:** `7C-1024x600-20211128.bin`, die erste Datei von
Waveshare. Sie hat 128 Byte **ohne** CEA-Block. Das Bild ist damit scharf,
aber der Pi behandelt das Panel als DVI-Monitor: ELD leer, `snd_pcm_open`
scheitert mit Fehler 524, kein Ton ueber HDMI.

### Rueckfall: selbst korrigiertes EDID

`edid/waveshare-1024x600.bin` (sha256
`72558fbc7e9ca45009d4a3a967eab4ea8473d0e7310897219505b0705c4ca8cb`) war bis
2026-09-29 die Vorgabe und bleibt als Rueckfall aufgehoben. Sie entsteht aus
dem EDID des Panels wie folgt.

Es genuegt, zwei Bytes im Detailtiming zu aendern - Front-Porch 5 -> 6 und
Sync-Breite 13 -> 12. Damit wird

```
hsync_start = 1030  (gerade)
hsync_end   = 1042  (gerade)
htotal      = 1312  (unveraendert)
```

Pixeltakt und Bildwiederholrate bleiben gleich, das Bild verschiebt sich um
einen Pixel. Alles andere am EDID bleibt unberuehrt.

#### 1. Blob erzeugen (auf dem Geraet, Panel angeschlossen)

```python
# mkedid.py
e = bytearray(open("/sys/class/drm/card1-HDMI-A-1/edid", "rb").read())
d = 54                      # erster Detailtiming-Block
e[d + 8] = 6                # Front-Porch 5 -> 6
e[d + 9] = 12               # Sync-Breite 13 -> 12
s = 0
for i in range(127):
    s = (s + e[i]) & 0xFF
e[127] = (256 - s) & 0xFF   # Pruefsumme Block 0 neu
open("waveshare-1024x600.bin", "wb").write(bytes(e))
```

Den Connector-Namen vorher pruefen (`ls /sys/class/drm/`), auf dem Pi 4 ist es
`card1-HDMI-A-1` fuer den HDMI-Anschluss neben dem Stromanschluss.

#### 2. Blob installieren

```bash
sudo mkdir -p /lib/firmware/edid
sudo cp waveshare-1024x600.bin /lib/firmware/edid/
```

#### 3. Kernel-Parameter setzen

In `/boot/firmware/cmdline.txt` an die **eine** Zeile anhaengen:

```
drm.edid_firmware=HDMI-A-1:edid/waveshare-1024x600.bin
```

**Achtung:** Der frueher gebraeuchliche Name `drm_kms_helper.edid_firmware`
wird von aktuellen Kerneln ignoriert (`unknown parameter ... ignored`) - er
heisst inzwischen `drm.edid_firmware`.

In `config.txt` bleibt `dtoverlay=vc4-kms-v3d` stehen, die `hdmi_*`-Zeilen
koennen weg.

#### 4. Gegenprobe nach dem Neustart

Gilt fuer beide Dateien.

```bash
head -1 /sys/class/drm/card1-HDMI-A-1/modes   # -> 1024x600
cat /sys/class/graphics/fb0/virtual_size      # -> 1024,600
dmesg | grep "not supported"                  # -> nichts
grep sad_count /proc/asound/card0/eld#0       # -> 1 (Audio ueber HDMI da)
```

ivi-homescreen meldet dann `mode=1024x600@60Hz` und
`Display metadata: 1024x600 logical -> 1024x600 px, pixel_ratio=1`.

## Rockchip RK3566 (BigTreeTech Pi2)

Getestet am 2026-11-11 auf einer BigTreeTech Pi2 (RK3566, Armbian trixie,
Kernel 6.18, VOP2 + DW-HDMI) mit demselben Panel. Ohne Vorgabe ist es wie
am Pi 4: das native 1024x600 fehlt, das Bild kommt in 1920x1080 und das Panel
skaliert herunter.

`waveshare-7h-260929.bin` hilft hier **nicht**. Der Rockchip-HDMI nimmt nur
Pixeltakte an, die seine Video-PLL genau trifft, und verwirft den Modus mit
`Rejected mode ... (NOCLOCK)` (sichtbar mit `drm.debug=0x4`):

```
angenommen: 74,25  78,75  108  135  148,5 MHz
verworfen:  25,175  27  31,5  36  40  50,25  65  75  88,75  136,75 MHz
```

Deshalb gibt es eine eigene Datei mit 74,25 MHz:
`edid/waveshare-7h-74m-1980x625.bin` (256 Byte, sha256
`77a3ba937cd66200968aee111ea594116d9959bb88b219f3e930fe63fe47ce33`).
Sie ist `waveshare-7h-260929.bin` mit geaendertem erstem Detailtiming:

```
1024x600, Pixeltakt 74250 kHz, 60,0 Hz
h: aktiv 1024, front 44, sync 88, total 1980
v: aktiv  600, front  3, sync  6, total  625
```

Zeilentakt (37,5 kHz) und Zeilenzahl bleiben fast wie beim Panel selbst
(37,4 kHz, 625), nur die horizontale Austastluecke ist laenger. Das Panel
nimmt das an, das Bild ist scharf. Der CEA-Block ist byte-gleich, die
Pruefsumme von Block 0 neu berechnet. Ton ueber HDMI auf der Pi2 ist damit
noch nicht geprueft.

Installation unter Armbian:

```bash
sudo cp waveshare-7h-74m-1980x625.bin /lib/firmware/edid/
# rockchipdrm laeuft schon im Initramfs -> Datei muss mit hinein
sudo tee /etc/initramfs-tools/hooks/edid >/dev/null <<'HOOK'
#!/bin/sh
[ "$1" = prereqs ] && exit 0
. /usr/share/initramfs-tools/hook-functions
copy_file firmware /lib/firmware/edid/waveshare-7h-74m-1980x625.bin
HOOK
sudo chmod +x /etc/initramfs-tools/hooks/edid
sudo update-initramfs -u
# /boot/armbianEnv.txt, Zeile extraargs ergaenzen:
#   extraargs=drm.edid_firmware=HDMI-A-1:edid/waveshare-7h-74m-1980x625.bin
```

Gegenprobe nach dem Neustart: dmesg meldet
`Loaded external firmware EDID "edid/waveshare-7h-74m-1980x625.bin"`, und in
`/sys/class/drm/card0-HDMI-A-1/modes` steht `1024x600` oben. Fehlt die Datei
im Initramfs, laedt der Kernel sie nicht und nimmt still das EDID des Panels.

## Touch

Der Touch des Panels laeuft ueber USB und braucht nichts weiter. Er meldet
sich als `STMicroelectronics 7H Custom Human interface` (USB-ID `0484:5750`),
mit `INPUT_PROP_DIRECT`, Multitouch-Achsen und `BTN_TOUCH`. libinput nimmt ihn
ohne Zutun auf. Gegenprobe ohne laufende App: `/dev/input/event*` des Geraets
mitlesen und das Panel beruehren.
