#!/bin/bash
# Linux/Mac Shell-Script zum Erstellen der hessen.mbtiles Datei
#
# Voraussetzungen:
#   - Python 3.10+ installiert
#   - pip install download-tiles

set -e  # Bei Fehler abbrechen

echo "================================================================================"
echo "Tile-Download Script für Hessen"
echo "================================================================================"
echo ""

# Prüfe ob Python installiert ist
if ! command -v python3 &> /dev/null; then
    echo "FEHLER: Python 3 ist nicht installiert"
    echo "Bitte installieren Sie Python 3.10 oder höher"
    exit 1
fi

echo "Python gefunden: $(python3 --version)"
echo ""

# Prüfe ob download-tiles installiert ist
if ! python3 -c "import download_tiles" 2>/dev/null; then
    echo ""
    echo "download-tiles Paket ist nicht installiert."
    read -p "Möchten Sie es jetzt installieren? (j/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Jj]$ ]]; then
        echo ""
        echo "Installiere download-tiles..."
        pip3 install download-tiles
    else
        echo "Installation abgebrochen."
        echo "Bitte führen Sie aus: pip3 install download-tiles"
        exit 1
    fi
fi

echo ""
echo "================================================================================"
echo "Starte Download der Kartendaten für Hessen"
echo "================================================================================"
echo ""
echo "Region:       Hessen, Deutschland"
echo "Bounding Box: 7.7726,49.3963,10.2358,51.6569"
echo "Zoom-Level:   10-14"
echo "Output:       hessen.mbtiles"
echo ""
echo "HINWEIS: Der Download kann 30-60 Minuten dauern und ~250 MB herunterladen."
echo "         Bitte nicht unterbrechen!"
echo ""
read -p "Drücken Sie Enter zum Starten..."

# Führe Python-Script aus
python3 download_tiles.py

if [ $? -eq 0 ]; then
    echo ""
    echo "================================================================================"
    echo "Download erfolgreich abgeschlossen!"
    echo "================================================================================"
    echo ""
    echo "Die Datei hessen.mbtiles wurde erstellt."
    echo "Sie können diese Datei nun in der Flutter-App verwenden."
    echo ""
else
    echo ""
    echo "================================================================================"
    echo "FEHLER: Download fehlgeschlagen"
    echo "================================================================================"
    echo ""
    echo "Bitte prüfen Sie:"
    echo "  - Internetverbindung"
    echo "  - Verfügbarer Speicherplatz (~250 MB erforderlich)"
    echo "  - OpenStreetMap Tile-Server ist erreichbar"
    echo ""
    exit 1
fi
