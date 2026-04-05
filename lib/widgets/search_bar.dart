import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import '../services/offline_geocoder.dart';

class PlaceSearchBar extends StatefulWidget {
  final MapController mapController;
  final OfflineGeocoder geocoder;
  final double initialZoom;

  const PlaceSearchBar({
    super.key,
    required this.mapController,
    required this.geocoder,
    this.initialZoom = 14,
  });

  @override
  State<PlaceSearchBar> createState() => _PlaceSearchBarState();
}

class _PlaceSearchBarState extends State<PlaceSearchBar> {
  late TextEditingController _searchController;
  List<GeocoderResult> _suggestions = [];
  bool _isLoading = false;
  bool _showSuggestions = false;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _focusNode.addListener(() {
      setState(() {
        if (!_focusNode.hasFocus) {
          _showSuggestions = false;
        }
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.isEmpty) {
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _showSuggestions = true;
    });

    try {
      final results = await widget.geocoder.search(
        query,
        limit: 10,
      );

      if (mounted) {
        setState(() {
          _suggestions = results;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _suggestions = [];
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Suchergebnis fehlgeschlagen: $e')),
        );
      }
    }
  }

  void _selectPlace(GeocoderResult result) {
    // Move map to selected location
    widget.mapController.move(
      result.location,
      result.zoom.toDouble(),
    );

    // Close suggestions
    _focusNode.unfocus();
    setState(() {
      _showSuggestions = false;
      _searchController.text = result.name;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: TextField(
            controller: _searchController,
            focusNode: _focusNode,
            onChanged: _search,
            decoration: InputDecoration(
              hintText: 'Ort suchen...',
              prefixIcon: const Icon(Icons.location_on),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _suggestions = [];
                          _showSuggestions = false;
                        });
                      },
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
        ),
        // Suggestions dropdown
        if (_showSuggestions && (_isLoading || _suggestions.isNotEmpty))
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            constraints: const BoxConstraints(maxHeight: 300),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: _isLoading
                ? const SizedBox(
                    height: 60,
                    child: Center(
                      child: CircularProgressIndicator(),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _suggestions.length,
                    itemBuilder: (context, index) {
                      final result = _suggestions[index];
                      return ListTile(
                        leading: _getTypeIcon(result.type),
                        title: Text(result.name),
                        subtitle: Text(
                          '${result.type}${result.detail != null ? ' • ${result.detail}' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _selectPlace(result),
                      );
                    },
                  ),
          ),
      ],
    );
  }

  Icon _getTypeIcon(String type) => switch (type) {
    'mountain_peak' => const Icon(Icons.terrain, color: Colors.brown),
    'poi' => const Icon(Icons.place, color: Colors.orange),
    _ => const Icon(Icons.location_city, color: Colors.blue),
  };
}
