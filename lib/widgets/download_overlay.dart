import 'package:flutter/material.dart';
import '../services/map_downloader.dart';
import '../config/map_config.dart';

/// Download-Status Enum
enum DownloadStatus {
  notDownloaded,
  downloading,
  downloaded,
  error,
}

/// Overlay-Widget für den Download der Kartendaten
class DownloadOverlay extends StatefulWidget {
  final MapDownloader downloader;
  final VoidCallback onDownloadComplete;

  const DownloadOverlay({
    super.key,
    required this.downloader,
    required this.onDownloadComplete,
  });

  @override
  State<DownloadOverlay> createState() => _DownloadOverlayState();
}

class _DownloadOverlayState extends State<DownloadOverlay> {
  DownloadStatus _status = DownloadStatus.notDownloaded;
  double _progress = 0.0;
  String? _errorMessage;

  String _storagePath = '';
  String _storageLocationName = '';

  @override
  void initState() {
    super.initState();
    _checkDownloadStatus();
    _loadStorageInfo();
  }

  Future<void> _loadStorageInfo() async {
    final path = await widget.downloader.getStoragePath();
    final locationName = widget.downloader.storageLocationName;
    if (mounted) {
      setState(() {
        _storagePath = path;
        _storageLocationName = locationName;
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
        title: const Text('Kartendaten löschen?'),
        content: const Text(
          'Möchten Sie die heruntergeladenen Kartendaten wirklich löschen?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Löschen'),
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
              'Kartendaten für Hessen',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Download erforderlich (~${MapConfig.estimatedFileSizeMB} MB)',
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Die Kartendaten werden lokal gespeichert und '
              'ermöglichen die Offline-Nutzung.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (_storageLocationName.isNotEmpty) ...[
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
                        Icon(Icons.folder, size: 16, color: Colors.blue.shade700),
                        const SizedBox(width: 8),
                        Text(
                          'Speicherort: $_storageLocationName',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.blue.shade900,
                          ),
                        ),
                      ],
                    ),
                    if (_storagePath.isNotEmpty) ...[
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
              'Download läuft...',
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
          'Kartendaten erfolgreich heruntergeladen!',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        );

      case DownloadStatus.error:
        return Column(
          children: [
            Text(
              'Download fehlgeschlagen',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.red,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage ?? 'Unbekannter Fehler',
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
          label: const Text('Jetzt herunterladen'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: 32,
              vertical: 16,
            ),
          ),
        );

      case DownloadStatus.downloading:
        return const SizedBox.shrink();

      case DownloadStatus.downloaded:
        return TextButton.icon(
          onPressed: _deleteMap,
          icon: const Icon(Icons.delete),
          label: const Text('Kartendaten löschen'),
        );

      case DownloadStatus.error:
        return ElevatedButton.icon(
          onPressed: _startDownload,
          icon: const Icon(Icons.refresh),
          label: const Text('Erneut versuchen'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: 32,
              vertical: 16,
            ),
          ),
        );
    }
  }
}
