import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/map_config.dart';
import '../services/map_downloader.dart';

/// Dialog zur Auswahl des Speicherorts für Offline-Karten
class StorageSettingsDialog extends StatefulWidget {
  final MapStorageLocation currentLocation;

  const StorageSettingsDialog({
    super.key,
    required this.currentLocation,
  });

  @override
  State<StorageSettingsDialog> createState() => _StorageSettingsDialogState();
}

class _StorageSettingsDialogState extends State<StorageSettingsDialog> {
  late MapStorageLocation _selectedLocation;
  final TextEditingController _customPathController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selectedLocation = widget.currentLocation;
    _customPathController.text = MapConfig.customStoragePath ?? '';
  }

  @override
  void dispose() {
    _customPathController.dispose();
    super.dispose();
  }

  Future<void> _saveAndClose() async {
    // Validierung für Custom Path
    if (_selectedLocation == MapStorageLocation.custom) {
      if (_customPathController.text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bitte geben Sie einen benutzerdefinierten Pfad an'),
          ),
        );
        return;
      }
      MapConfig.customStoragePath = _customPathController.text;
    }

    // Speichere in SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('storage_location', _selectedLocation.name);
    if (_selectedLocation == MapStorageLocation.custom) {
      await prefs.setString('custom_storage_path', _customPathController.text);
    }

    if (mounted) {
      Navigator.of(context).pop(_selectedLocation);
    }
  }

  String _getLocationDescription(MapStorageLocation location) {
    switch (location) {
      case MapStorageLocation.applicationSupport:
        return 'Empfohlen für App-interne Daten\n'
            'Windows: AppData\\Roaming\n'
            'Android: /data/data/<app>/files';
      case MapStorageLocation.applicationDocuments:
        return 'Für benutzergenerierte Daten\n'
            'Windows: Dokumente\n'
            'Android: Documents';
      case MapStorageLocation.downloads:
        return 'Im Download-Ordner\n'
            'Leicht für Benutzer zugänglich';
      case MapStorageLocation.externalStorage:
        return 'Nur Android\n'
            'Externer Speicher/SD-Karte';
      case MapStorageLocation.custom:
        return 'Benutzerdefinierter Pfad\n'
            'Volle Kontrolle über Speicherort';
    }
  }

  String _getLocationTitle(MapStorageLocation location) {
    switch (location) {
      case MapStorageLocation.applicationSupport:
        return 'Application Support (Standard)';
      case MapStorageLocation.applicationDocuments:
        return 'Dokumente';
      case MapStorageLocation.downloads:
        return 'Downloads';
      case MapStorageLocation.externalStorage:
        return 'External Storage (Android)';
      case MapStorageLocation.custom:
        return 'Benutzerdefiniert';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Speicherort wählen'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Wählen Sie, wo die Offline-Kartendaten gespeichert werden sollen:',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              RadioGroup<MapStorageLocation>(
                groupValue: _selectedLocation,
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _selectedLocation = value;
                  });
                },
                child: Column(
                  children: MapStorageLocation.values.map((location) {
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: RadioListTile<MapStorageLocation>(
                        value: location,
                        title: Text(_getLocationTitle(location)),
                        subtitle: Text(
                          _getLocationDescription(location),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              if (_selectedLocation == MapStorageLocation.custom) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _customPathController,
                  decoration: const InputDecoration(
                    labelText: 'Benutzerdefinierter Pfad',
                    hintText: 'z.B. D:/Maps oder /home/user/maps',
                    border: OutlineInputBorder(),
                    helperText: 'Absoluter Pfad zum Zielverzeichnis',
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning, color: Colors.amber.shade700),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Änderungen erfordern einen Neustart der App. '
                        'Vorhandene Kartendaten müssen neu heruntergeladen werden.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.amber.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Abbrechen'),
        ),
        ElevatedButton(
          onPressed: _saveAndClose,
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}

/// Utility-Klasse zum Laden/Speichern der Storage-Einstellungen
class StoragePreferences {
  static const String _keyStorageLocation = 'storage_location';
  static const String _keyCustomPath = 'custom_storage_path';

  /// Lädt die gespeicherten Speicherort-Einstellungen
  static Future<MapStorageLocation> loadStorageLocation() async {
    final prefs = await SharedPreferences.getInstance();
    final locationName = prefs.getString(_keyStorageLocation);

    if (locationName == null) {
      return MapConfig.defaultStorageLocation;
    }

    try {
      return MapStorageLocation.values.firstWhere(
        (e) => e.name == locationName,
        orElse: () => MapConfig.defaultStorageLocation,
      );
    } catch (e) {
      return MapConfig.defaultStorageLocation;
    }
  }

  /// Lädt den benutzerdefinierten Pfad
  static Future<String?> loadCustomPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyCustomPath);
  }

  /// Erstellt einen MapDownloader mit den gespeicherten Einstellungen
  static Future<MapDownloader> createDownloader() async {
    final location = await loadStorageLocation();
    final customPath = await loadCustomPath();

    if (location == MapStorageLocation.custom && customPath != null) {
      MapConfig.customStoragePath = customPath;
    }

    return MapDownloader(
      storageLocation: location,
      customPath: customPath,
    );
  }
}
