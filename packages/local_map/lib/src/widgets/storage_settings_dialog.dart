import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/map_config.dart';
import '../services/map_downloader.dart';

/// Texte von [StorageSettingsDialog]. Die Vorgaben sind englisch, [german] ist
/// die deutsche Fassung; andere Sprachen legt der Gastgeber selbst an.
class StorageSettingsTexts {
  final String title;
  final String intro;
  final String Function(MapStorageLocation location) locationTitle;
  final String Function(MapStorageLocation location) locationDescription;
  final String customPathLabel;
  final String customPathHint;
  final String customPathHelper;
  final String customPathMissing;
  final String restartWarning;
  final String cancel;
  final String save;

  const StorageSettingsTexts({
    this.title = 'Choose storage location',
    this.intro = 'Choose where the offline map data is stored:',
    this.locationTitle = _locationTitleEn,
    this.locationDescription = _locationDescriptionEn,
    this.customPathLabel = 'Custom path',
    this.customPathHint = 'e.g. D:/Maps or /home/user/maps',
    this.customPathHelper = 'Absolute path to the target directory',
    this.customPathMissing = 'Please enter a custom path',
    this.restartWarning =
        'Changes take effect after restarting the app. '
        'Existing map data has to be downloaded again.',
    this.cancel = 'Cancel',
    this.save = 'Save',
  });

  static const german = StorageSettingsTexts(
    title: 'Speicherort wählen',
    intro: 'Wählen Sie, wo die Offline-Kartendaten gespeichert werden sollen:',
    locationTitle: _locationTitleDe,
    locationDescription: _locationDescriptionDe,
    customPathLabel: 'Benutzerdefinierter Pfad',
    customPathHint: 'z.B. D:/Maps oder /home/user/maps',
    customPathHelper: 'Absoluter Pfad zum Zielverzeichnis',
    customPathMissing: 'Bitte geben Sie einen benutzerdefinierten Pfad an',
    restartWarning:
        'Änderungen erfordern einen Neustart der App. '
        'Vorhandene Kartendaten müssen neu heruntergeladen werden.',
    cancel: 'Abbrechen',
    save: 'Speichern',
  );

  static String _locationTitleEn(MapStorageLocation location) =>
      switch (location) {
        MapStorageLocation.applicationSupport =>
          'Application Support (default)',
        MapStorageLocation.applicationDocuments => 'Documents',
        MapStorageLocation.downloads => 'Downloads',
        MapStorageLocation.externalStorage => 'External Storage (Android)',
        MapStorageLocation.custom => 'Custom',
      };

  static String _locationTitleDe(MapStorageLocation location) =>
      switch (location) {
        MapStorageLocation.applicationSupport =>
          'Application Support (Standard)',
        MapStorageLocation.applicationDocuments => 'Dokumente',
        MapStorageLocation.downloads => 'Downloads',
        MapStorageLocation.externalStorage => 'External Storage (Android)',
        MapStorageLocation.custom => 'Benutzerdefiniert',
      };

  static String _locationDescriptionEn(MapStorageLocation location) =>
      switch (location) {
        MapStorageLocation.applicationSupport =>
          'Recommended for internal app data\n'
              'Windows: AppData\\Roaming\n'
              'Android: /data/data/<app>/files',
        MapStorageLocation.applicationDocuments =>
          'For user-generated data\n'
              'Windows: Documents\n'
              'Android: Documents',
        MapStorageLocation.downloads =>
          'In the downloads folder\n'
              'Easy for users to reach',
        MapStorageLocation.externalStorage =>
          'Android only\n'
              'External storage/SD card',
        MapStorageLocation.custom =>
          'Custom path\n'
              'Full control over the location',
      };

  static String _locationDescriptionDe(MapStorageLocation location) =>
      switch (location) {
        MapStorageLocation.applicationSupport =>
          'Empfohlen für App-interne Daten\n'
              'Windows: AppData\\Roaming\n'
              'Android: /data/data/<app>/files',
        MapStorageLocation.applicationDocuments =>
          'Für benutzergenerierte Daten\n'
              'Windows: Dokumente\n'
              'Android: Documents',
        MapStorageLocation.downloads =>
          'Im Download-Ordner\n'
              'Leicht für Benutzer zugänglich',
        MapStorageLocation.externalStorage =>
          'Nur Android\n'
              'Externer Speicher/SD-Karte',
        MapStorageLocation.custom =>
          'Benutzerdefinierter Pfad\n'
              'Volle Kontrolle über Speicherort',
      };
}

/// Dialog zur Auswahl des Speicherorts für Offline-Karten
class StorageSettingsDialog extends StatefulWidget {
  final MapStorageLocation currentLocation;

  /// Liefert den vorbelegten benutzerdefinierten Pfad.
  /// Ohne Angabe wird [MapConfig.defaults] verwendet.
  final MapConfig? config;

  final StorageSettingsTexts texts;

  const StorageSettingsDialog({
    super.key,
    required this.currentLocation,
    this.config,
    this.texts = const StorageSettingsTexts(),
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
    _customPathController.text =
        (widget.config ?? MapConfig.defaults).customStoragePath ?? '';
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(widget.texts.customPathMissing)));
        return;
      }
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

  @override
  Widget build(BuildContext context) {
    final texts = widget.texts;
    return AlertDialog(
      title: Text(texts.title),
      content: SingleChildScrollView(
        child: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(texts.intro, style: Theme.of(context).textTheme.bodyMedium),
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
                        title: Text(texts.locationTitle(location)),
                        subtitle: Text(
                          texts.locationDescription(location),
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
                  decoration: InputDecoration(
                    labelText: texts.customPathLabel,
                    hintText: texts.customPathHint,
                    border: const OutlineInputBorder(),
                    helperText: texts.customPathHelper,
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
                        texts.restartWarning,
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
          child: Text(texts.cancel),
        ),
        ElevatedButton(onPressed: _saveAndClose, child: Text(texts.save)),
      ],
    );
  }
}

/// Utility-Klasse zum Laden/Speichern der Storage-Einstellungen
class StoragePreferences {
  static const String _keyStorageLocation = 'storage_location';
  static const String _keyCustomPath = 'custom_storage_path';

  /// Lädt die gespeicherten Speicherort-Einstellungen
  ///
  /// [config] liefert den Fallback, wenn nichts gespeichert ist.
  /// Ohne Angabe wird [MapConfig.defaults] verwendet.
  static Future<MapStorageLocation> loadStorageLocation({
    MapConfig? config,
  }) async {
    final fallback = (config ?? MapConfig.defaults).storageLocation;
    final prefs = await SharedPreferences.getInstance();
    final locationName = prefs.getString(_keyStorageLocation);

    if (locationName == null) {
      return fallback;
    }

    try {
      return MapStorageLocation.values.firstWhere(
        (e) => e.name == locationName,
        orElse: () => fallback,
      );
    } catch (e) {
      return fallback;
    }
  }

  /// Lädt den benutzerdefinierten Pfad
  static Future<String?> loadCustomPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyCustomPath);
  }

  /// Erstellt einen MapDownloader mit den gespeicherten Einstellungen
  ///
  /// Gibt eine [MapConfig] zurück, in der Speicherort und benutzerdefinierter
  /// Pfad aus den SharedPreferences eingesetzt sind.
  static Future<MapConfig> resolveConfig({MapConfig? config}) async {
    final base = config ?? MapConfig.defaults;
    final location = await loadStorageLocation(config: base);
    final customPath = await loadCustomPath();

    return base.copyWith(
      storageLocation: location,
      customStoragePath: customPath ?? base.customStoragePath,
    );
  }

  /// Erstellt einen MapDownloader mit den gespeicherten Einstellungen
  static Future<MapDownloader> createDownloader({MapConfig? config}) async {
    return MapDownloader(config: await resolveConfig(config: config));
  }
}
