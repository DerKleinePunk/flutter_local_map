import 'package:flutter/material.dart';
import '../config/map_config.dart';
import '../services/map_downloader.dart';

/// Texte von [DownloadOverlay]. Die Vorgaben sind englisch, [german] ist die
/// deutsche Fassung; andere Sprachen legt der Gastgeber selbst an.
class DownloadOverlayTexts {
  final String title;
  final String Function(int sizeMB) downloadRequired;
  final String offlineHint;

  /// Vor dem Namen des Speicherorts, gefolgt von einem Doppelpunkt.
  final String storageLocation;
  final String Function(MapStorageLocation location) locationName;
  final String downloading;
  final String downloaded;
  final String downloadFailed;
  final String unknownError;
  final String downloadNow;
  final String deleteMap;
  final String deleteTitle;
  final String deleteQuestion;
  final String cancel;
  final String delete;
  final String retry;

  const DownloadOverlayTexts({
    this.title = 'Map data',
    this.downloadRequired = _downloadRequiredEn,
    this.offlineHint =
        'The map data is stored locally and works without a connection.',
    this.storageLocation = 'Storage location',
    this.locationName = _locationNameEn,
    this.downloading = 'Downloading...',
    this.downloaded = 'Map data downloaded',
    this.downloadFailed = 'Download failed',
    this.unknownError = 'Unknown error',
    this.downloadNow = 'Download now',
    this.deleteMap = 'Delete map data',
    this.deleteTitle = 'Delete map data?',
    this.deleteQuestion =
        'Do you really want to delete the downloaded map data?',
    this.cancel = 'Cancel',
    this.delete = 'Delete',
    this.retry = 'Retry',
  });

  static const german = DownloadOverlayTexts(
    title: 'Kartendaten',
    downloadRequired: _downloadRequiredDe,
    offlineHint:
        'Die Kartendaten werden lokal gespeichert und '
        'ermöglichen die Offline-Nutzung.',
    storageLocation: 'Speicherort',
    locationName: _locationNameDe,
    downloading: 'Download läuft...',
    downloaded: 'Kartendaten erfolgreich heruntergeladen!',
    downloadFailed: 'Download fehlgeschlagen',
    unknownError: 'Unbekannter Fehler',
    downloadNow: 'Jetzt herunterladen',
    deleteMap: 'Kartendaten löschen',
    deleteTitle: 'Kartendaten löschen?',
    deleteQuestion:
        'Möchten Sie die heruntergeladenen Kartendaten wirklich löschen?',
    cancel: 'Abbrechen',
    delete: 'Löschen',
    retry: 'Erneut versuchen',
  );

  static String _downloadRequiredEn(int sizeMB) =>
      'Download required (~$sizeMB MB)';

  static String _downloadRequiredDe(int sizeMB) =>
      'Download erforderlich (~$sizeMB MB)';

  static String _locationNameEn(MapStorageLocation location) =>
      switch (location) {
        MapStorageLocation.applicationSupport => 'Application Support',
        MapStorageLocation.applicationDocuments => 'Documents',
        MapStorageLocation.downloads => 'Downloads',
        MapStorageLocation.externalStorage => 'External Storage',
        MapStorageLocation.custom => 'Custom',
      };

  static String _locationNameDe(MapStorageLocation location) =>
      switch (location) {
        MapStorageLocation.applicationSupport => 'Application Support',
        MapStorageLocation.applicationDocuments => 'Dokumente',
        MapStorageLocation.downloads => 'Downloads',
        MapStorageLocation.externalStorage => 'Externer Speicher',
        MapStorageLocation.custom => 'Benutzerdefiniert',
      };
}

/// Download-Status Enum
enum DownloadStatus { notDownloaded, downloading, downloaded, error }

/// Overlay-Widget für den Download der Kartendaten
class DownloadOverlay extends StatefulWidget {
  final MapDownloader downloader;
  final VoidCallback onDownloadComplete;

  /// Überschrift über dem Download-Button, z.B. "Kartendaten für Hessen".
  /// Überschreibt [DownloadOverlayTexts.title].
  final String? title;
  final DownloadOverlayTexts texts;

  const DownloadOverlay({
    super.key,
    required this.downloader,
    required this.onDownloadComplete,
    this.title,
    this.texts = const DownloadOverlayTexts(),
  });

  @override
  State<DownloadOverlay> createState() => _DownloadOverlayState();
}

class _DownloadOverlayState extends State<DownloadOverlay> {
  DownloadStatus _status = DownloadStatus.notDownloaded;
  double _progress = 0.0;
  String? _errorMessage;

  String _storagePath = '';

  DownloadOverlayTexts get _texts => widget.texts;

  @override
  void initState() {
    super.initState();
    _checkDownloadStatus();
    _loadStorageInfo();
  }

  Future<void> _loadStorageInfo() async {
    final path = await widget.downloader.getStoragePath();
    if (mounted) {
      setState(() {
        _storagePath = path;
      });
    }
  }

  Future<void> _checkDownloadStatus() async {
    final isDownloaded = await widget.downloader.isMapDownloaded();
    if (mounted) {
      setState(() {
        _status = isDownloaded
            ? DownloadStatus.downloaded
            : DownloadStatus.notDownloaded;
      });

      if (isDownloaded) {
        widget.onDownloadComplete();
      }
    }
  }

  Future<void> _startDownload() async {
    setState(() {
      _status = DownloadStatus.downloading;
      _progress = 0.0;
      _errorMessage = null;
    });

    try {
      await widget.downloader.downloadMap(
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _progress = progress;
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _status = DownloadStatus.downloaded;
        });
        widget.onDownloadComplete();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = DownloadStatus.error;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _deleteMap() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_texts.deleteTitle),
        content: Text(_texts.deleteQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_texts.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_texts.delete),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.downloader.deleteMap();
      if (mounted) {
        setState(() {
          _status = DownloadStatus.notDownloaded;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Card(
            elevation: 8,
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildStatusIcon(),
                  const SizedBox(height: 24),
                  _buildStatusText(),
                  const SizedBox(height: 24),
                  _buildActionButton(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIcon() {
    IconData icon;
    Color color;

    switch (_status) {
      case DownloadStatus.notDownloaded:
        icon = Icons.download;
        color = Colors.blue;
        break;
      case DownloadStatus.downloading:
        icon = Icons.downloading;
        color = Colors.orange;
        break;
      case DownloadStatus.downloaded:
        icon = Icons.check_circle;
        color = Colors.green;
        break;
      case DownloadStatus.error:
        icon = Icons.error;
        color = Colors.red;
        break;
    }

    return Icon(icon, size: 64, color: color);
  }

  Widget _buildStatusText() {
    switch (_status) {
      case DownloadStatus.notDownloaded:
        return Column(
          children: [
            Text(
              widget.title ?? _texts.title,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _texts.downloadRequired(
                widget.downloader.config.estimatedFileSizeMB,
              ),
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _texts.offlineHint,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (_storagePath.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.folder,
                          size: 16,
                          color: Colors.blue.shade700,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${_texts.storageLocation}: '
                          '${_texts.locationName(widget.downloader.config.storageLocation)}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.blue.shade900,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _storagePath,
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.blue.shade700,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ],
        );

      case DownloadStatus.downloading:
        return Column(
          children: [
            Text(
              _texts.downloading,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 8),
            Text(
              '${(_progress * 100).toStringAsFixed(0)}%',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        );

      case DownloadStatus.downloaded:
        return Text(
          _texts.downloaded,
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        );

      case DownloadStatus.error:
        return Column(
          children: [
            Text(
              _texts.downloadFailed,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(color: Colors.red),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage ?? _texts.unknownError,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        );
    }
  }

  Widget _buildActionButton() {
    switch (_status) {
      case DownloadStatus.notDownloaded:
        return ElevatedButton.icon(
          onPressed: _startDownload,
          icon: const Icon(Icons.download),
          label: Text(_texts.downloadNow),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          ),
        );

      case DownloadStatus.downloading:
        return const SizedBox.shrink();

      case DownloadStatus.downloaded:
        return TextButton.icon(
          onPressed: _deleteMap,
          icon: const Icon(Icons.delete),
          label: Text(_texts.deleteMap),
        );

      case DownloadStatus.error:
        return ElevatedButton.icon(
          onPressed: _startDownload,
          icon: const Icon(Icons.refresh),
          label: Text(_texts.retry),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          ),
        );
    }
  }
}
