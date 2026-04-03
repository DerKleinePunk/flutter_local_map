@echo off
REM Windows Batch-Script zum Erstellen der hessen.mbtiles Datei
REM
REM Voraussetzungen:
REM   - Python 3.10+ installiert
REM   - pip install download-tiles

echo ================================================================================
echo Tile-Download Script für Hessen
echo ================================================================================
echo.

REM Prüfe ob Python installiert ist
python --version >nul 2>&1
if %errorlevel% neq 0 (
    echo FEHLER: Python ist nicht installiert oder nicht im PATH
    echo Bitte installieren Sie Python von https://www.python.org/
    pause
    exit /b 1
)

echo Python gefunden: 
python --version
echo.

REM Prüfe ob download-tiles installiert ist
python -c "import sys; sys.exit(0 if __import__('importlib.util').find_spec('download_tiles') else 1)" >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo download-tiles Paket ist nicht installiert.
    echo Möchten Sie es jetzt installieren? (J/N)
    set /p install_choice=
    if /i "%install_choice%"=="J" (
        echo.
        echo Installiere download-tiles...
        pip install download-tiles
        if %errorlevel% neq 0 (
            echo FEHLER: Installation fehlgeschlagen
            pause
            exit /b 1
        )
    ) else (
        echo Installation abgebrochen.
        echo Bitte führen Sie aus: pip install download-tiles
        pause
        exit /b 1
    )
)

echo.
echo ================================================================================
echo Starte Download der Kartendaten für Hessen
echo ================================================================================
echo.
echo Region:      Hessen, Deutschland
echo Bounding Box: 7.7726,49.3963,10.2358,51.6569
echo Zoom-Level:  10-14
echo Output:      hessen.mbtiles
echo.
echo HINWEIS: Der Download kann 30-60 Minuten dauern und ~250 MB herunterladen.
echo          Bitte nicht unterbrechen!
echo.
echo Drücken Sie eine beliebige Taste zum Starten...
pause >nul

REM Führe Python-Script aus
python download_tiles.py

if %errorlevel% equ 0 (
    echo.
    echo ================================================================================
    echo Download erfolgreich abgeschlossen!
    echo ================================================================================
    echo.
    echo Die Datei hessen.mbtiles wurde erstellt.
    echo Sie können diese Datei nun in der Flutter-App verwenden.
    echo.
) else (
    echo.
    echo ================================================================================
    echo FEHLER: Download fehlgeschlagen
    echo ================================================================================
    echo.
    echo Bitte prüfen Sie:
    echo   - Internetverbindung
    echo   - Verfügbarer Speicherplatz (~250 MB erforderlich)
    echo   - OpenStreetMap Tile-Server ist erreichbar
    echo.
)

pause
