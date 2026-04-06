import 'dart:async';
import 'dart:ui';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'config/map_config.dart';
import 'services/map_downloader.dart';
import 'widgets/map_view.dart';
import 'widgets/download_overlay.dart';
import 'widgets/storage_settings_dialog.dart';

void _logError(String source, Object error, StackTrace? stack) {
  final timestamp = DateTime.now().toIso8601String();
  // ignore: avoid_print
  print('[$timestamp] [$source] $error');
  if (stack != null) {
    // ignore: avoid_print
    print(stack);
  }
}

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }

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
      builder: (context) =>
          StorageSettingsDialog(currentLocation: currentLocation),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline-Karte Hessen'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: _showMenu,
            tooltip: 'Optionen',
          ),
        ],
      ),
      body: _buildBody(),
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
      );
    }

    return MapView(mbtilesPath: _mbtilesPath);
  }
}
