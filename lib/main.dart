import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_map/local_map.dart';

import 'map_bench.dart';
import 'map_screen.dart';

void _logError(String source, Object error, StackTrace? stack) {
  final timestamp = DateTime.now().toIso8601String();
  // ignore: avoid_print
  print('[$timestamp] [$source] $error');
  if (stack != null) {
    // ignore: avoid_print
    print(stack);
  }
}

/// Laeuft ab dem ersten Befehl, damit der Messlauf die Startzeit kennt.
final _sinceMain = Stopwatch()..start();

/// Nur gesetzt, wenn `LOCAL_MAP_BENCH` in der Umgebung steht.
final _bench = MapBench.fromEnvironment();

void main() {
  runZonedGuarded(
    () async {
      // Initialisiert Binding + sqflite-FFI und legt die Karten-Config fest,
      // die MapView/MapDownloader ohne explizites config:-Argument verwenden.
      LocalMap.ensureInitialized(config: MapConfig.hessen);

      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        _logError('FlutterError', details.exception, details.stack);
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        _logError('PlatformDispatcher', error, stack);
        return true;
      };

      runApp(const MyApp());
    },
    (error, stack) {
      _logError('runZonedGuarded', error, stack);
    },
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline-Karte Hessen',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MapHomePage(),
    );
  }
}

class MapHomePage extends StatefulWidget {
  const MapHomePage({super.key});

  @override
  State<MapHomePage> createState() => _MapHomePageState();
}

class _MapHomePageState extends State<MapHomePage> {
  late MapDownloader _downloader;
  bool _isInitialized = false;
  bool _isMapAvailable = false;
  String? _mbtilesPath;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // Lade gespeicherte Storage-Einstellungen
    _downloader = await StoragePreferences.createDownloader();
    await _downloader.initialize();
    final isAvailable = await _downloader.isMapDownloaded();

    if (isAvailable) {
      final path = await _downloader.getMBTilesPath();
      if (mounted) {
        setState(() {
          _isMapAvailable = true;
          _mbtilesPath = path;
          _isInitialized = true;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    }
  }

  Future<void> _onDownloadComplete() async {
    final path = await _downloader.getMBTilesPath();
    if (mounted) {
      setState(() {
        _isMapAvailable = true;
        _mbtilesPath = path;
      });
    }
  }

  /// Beendet die Anwendung.
  ///
  /// Unter DRM/KMS gibt es keinen Fensterrahmen und damit kein X des
  /// Fenstermanagers. Ohne diesen Weg bleibt nur SSH und `pkill -x`.
  ///
  /// [SystemNavigator.pop] zuerst, weil ein Desktop-Embedder das Fenster
  /// damit regulär schließt. Der ivi-homescreen-Embedder kennt auf dem Kanal
  /// `flutter/platform` nur die Zwischenablage, dort bleibt der Aufruf also
  /// wirkungslos — deshalb danach der harte Ausstieg. Die MBTiles sind
  /// schreibgeschützt geöffnet, es geht dabei nichts verloren.
  Future<void> _quit() async {
    await SystemNavigator.pop();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    exit(0);
  }

  /// Fragt vor dem Beenden nach.
  ///
  /// Auf dem Zielgerät hängt die App im Vollbild ohne Rahmen: ein
  /// versehentlicher Treffer auf das X würde den Bildschirm schwarz
  /// zurücklassen, und zurück käme man nur über SSH.
  Future<void> _confirmQuit() async {
    final shouldQuit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Beenden'),
        content: const Text('Die Anwendung wirklich schließen?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Beenden'),
          ),
        ],
      ),
    );

    if ((shouldQuit ?? false) && mounted) {
      await _quit();
    }
  }

  Future<void> _showMenu() async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Optionen'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder),
              title: const Text('Speicherort ändern'),
              onTap: () => Navigator.pop(context, 'storage'),
            ),
            ListTile(
              leading: const Icon(Icons.info),
              title: const Text('Über'),
              onTap: () => Navigator.pop(context, 'about'),
            ),
            if (_isMapAvailable)
              ListTile(
                leading: const Icon(Icons.delete),
                title: const Text('Kartendaten löschen'),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Neu laden'),
              onTap: () => Navigator.pop(context, 'reload'),
            ),
          ],
        ),
      ),
    );

    if (result == 'storage' && mounted) {
      await _showStorageSettings();
    } else if (result == 'about' && mounted) {
      _showAboutDialog();
    } else if (result == 'delete' && mounted) {
      await _deleteMap();
    } else if (result == 'reload' && mounted) {
      setState(() {
        _isInitialized = false;
      });
      await _initialize();
    }
  }

  Future<void> _showStorageSettings() async {
    final currentLocation = await StoragePreferences.loadStorageLocation();

    if (!mounted) return;

    final result = await showDialog<MapStorageLocation>(
      context: context,
      builder: (context) => StorageSettingsDialog(
        currentLocation: currentLocation,
        config: _downloader.config,
      ),
    );

    if (result != null && mounted) {
      // Zeige Info-Dialog über notwendigen Neustart
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Neustart erforderlich'),
          content: const Text(
            'Die Speicherort-Änderung wird beim nächsten App-Start wirksam. '
            'Bitte starten Sie die Anwendung neu.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  void _showAboutDialog() {
    showAboutDialog(
      context: context,
      applicationName: 'Offline-Karte Hessen',
      applicationVersion: '1.0.0',
      children: [
        const Text(
          'Desktop-Anwendung zur Darstellung von '
          'Offline-Kartendaten für die Region Hessen.',
        ),
        const SizedBox(height: 16),
        const Text(
          'Kartendaten: © OpenStreetMap contributors',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  Future<void> _deleteMap() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kartendaten löschen?'),
        content: const Text(
          'Möchten Sie die heruntergeladenen Kartendaten wirklich löschen? '
          'Sie können diese jederzeit erneut herunterladen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _downloader.deleteMap();
      if (mounted) {
        setState(() {
          _isMapAvailable = false;
          _mbtilesPath = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Strg+Q zusätzlich zum X: auf dem Zielgerät ist die Zeigereingabe ein
    // Touchpad an einer Funktastatur, da ist ein Tastenkürzel oft schneller
    // als das Zielen auf ein 40-px-Feld.
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyQ, control: true):
            _confirmQuit,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Offline-Karte Hessen'),
            backgroundColor: Theme.of(context).colorScheme.inversePrimary,
            actions: [
              // semanticLabel, nicht nur tooltip: ohne Zeiger gibt es keinen
              // Tooltip, und im Semantikbaum stehen die Schaltflaechen sonst
              // ohne Namen da - weder ein Screenreader noch die MCP-Bedienung
              // koennen sie dann auseinanderhalten.
              IconButton(
                icon: const Icon(Icons.more_vert, semanticLabel: 'Optionen'),
                onPressed: _showMenu,
                tooltip: 'Optionen',
              ),
              IconButton(
                icon: const Icon(Icons.close, semanticLabel: 'Beenden'),
                onPressed: _confirmQuit,
                tooltip: 'Beenden (Strg+Q)',
              ),
            ],
          ),
          body: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (!_isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_isMapAvailable) {
      return DownloadOverlay(
        downloader: _downloader,
        onDownloadComplete: _onDownloadComplete,
        title: 'Kartendaten für Hessen',
      );
    }

    final bench = _bench;
    if (bench != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => bench.start(_sinceMain),
      );
    }

    return wrapForBench(
      bench,
      MapScreen(
        mbtilesPath: _mbtilesPath,
        // Die Config aus LocalMap.ensureInitialized().
        config: MapConfig.defaults,
        mapController: bench?.mapController,
      ),
    );
  }
}
