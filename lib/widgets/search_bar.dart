import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import '../services/offline_geocoder.dart';

/// Extensions for GeocoderResult to provide type labels and sorting priority
extension GeocoderResultExtension on GeocoderResult {
  /// Get a human-readable type label in German
  String get typeLabel => switch (type) {
    'place' => 'Ort',
    'poi' => 'POI',
    'mountain_peak' => 'Berg',
    'water_name' => 'Gewässer',
    'transportation_name' => 'Straße',
    _ => type,
  };

  /// Get type priority for sorting (lower = higher priority)
  int get typePriority => switch (type) {
    'place' => 0,
    'poi' => 1,
    'mountain_peak' => 2,
    'water_name' => 3,
    'transportation_name' => 4,
    _ => 99,
  };
}

class PlaceSearchBar extends StatefulWidget {
  final MapController mapController;
  final OfflineGeocoder geocoder;
  final double initialZoom;
  final Future<List<GeocoderResult>> Function(String query, int limit)?
  searchDelegate;
  final ValueChanged<GeocoderResult>? onPlaceSelected;
  final ValueChanged<GeocoderResult>? onSuggestionPointerDown;
  final void Function(MapController controller, GeocoderResult result)?
  moveToResult;

  const PlaceSearchBar({
    super.key,
    required this.mapController,
    required this.geocoder,
    this.initialZoom = 14,
    this.searchDelegate,
    this.onPlaceSelected,
    this.onSuggestionPointerDown,
    this.moveToResult,
  });

  @override
  State<PlaceSearchBar> createState() => _PlaceSearchBarState();
}

class _PlaceSearchBarState extends State<PlaceSearchBar> {
  late TextEditingController _searchController;
  List<GeocoderResult> _suggestions = [];
  bool _isLoading = false;
  bool _showSuggestions = false;
  bool _isSelectingSuggestion = false;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        return;
      }

      // Delay hiding a bit so a tap on a suggestion can be delivered first.
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (!mounted || _focusNode.hasFocus || _isSelectingSuggestion) {
          return;
        }
        setState(() {
          _showSuggestions = false;
        });
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
      final results =
          await (widget.searchDelegate?.call(query, 15) ??
              widget.geocoder.searchPrioritized(query, limit: 15));

      // Results are already sorted by searchPrioritized, but ensure consistency
      results.sort(
        (a, b) => a.typePriority.compareTo(b.typePriority) == 0
            ? a.name.compareTo(b.name)
            : a.typePriority.compareTo(b.typePriority),
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
    _isSelectingSuggestion = true;
    debugPrint(
      '[search] Selected place: ${result.name} at ${result.location}, zoom: ${result.zoom}',
    );

    widget.onPlaceSelected?.call(result);

    // Move map to selected location
    if (widget.moveToResult != null) {
      widget.moveToResult!(widget.mapController, result);
    } else {
      widget.mapController.moveAndRotate(
        result.location,
        result.zoom.toDouble(),
        0.0,
      );
    }

    // Close suggestions
    _focusNode.unfocus();
    setState(() {
      _showSuggestions = false;
      _searchController.text = result.name;
    });

    _isSelectingSuggestion = false;
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
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
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
                    child: Center(child: CircularProgressIndicator()),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _suggestions.length,
                    itemBuilder: (context, index) {
                      final result = _suggestions[index];
                      final subtitle = StringBuffer(result.typeLabel);
                      if (result.detail != null) {
                        subtitle.write(' • ${result.detail}');
                      }
                      subtitle.write(' • z${result.zoom}');
                      return Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (_) {
                          _isSelectingSuggestion = true;
                          widget.onSuggestionPointerDown?.call(result);
                          debugPrint(
                            '[search] Pointer down on suggestion: ${result.name}',
                          );
                        },
                        child: ListTile(
                          leading: _getTypeIcon(result.type),
                          title: Text(result.name),
                          subtitle: Text(
                            subtitle.toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _selectPlace(result),
                        ),
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
