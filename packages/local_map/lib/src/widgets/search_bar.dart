import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../api/place_search.dart';
import '../services/offline_geocoder.dart';

/// Texte von [PlaceSearchBar]. Die Vorgaben sind englisch, [german] ist die
/// deutsche Fassung; andere Sprachen legt der Gastgeber selbst an.
class PlaceSearchTexts {
  final String hintText;

  /// Snackbar, wenn die Suche scheitert; der Fehler folgt nach einem Doppelpunkt.
  final String searchFailed;

  final String place;
  final String poi;
  final String mountainPeak;
  final String water;
  final String street;

  /// Vor dem größeren Ort, den ein Ort als [GeocoderResult.area] mitbringt:
  /// "Neustadt · bei Marburg".
  final String near;

  /// Trenner in Entfernungen wie "3.2 km".
  final String decimalSeparator;

  const PlaceSearchTexts({
    this.hintText = 'Search place...',
    this.searchFailed = 'Search failed',
    this.place = 'Place',
    this.poi = 'POI',
    this.mountainPeak = 'Peak',
    this.water = 'Water',
    this.street = 'Street',
    this.near = 'near',
    this.decimalSeparator = '.',
  });

  static const german = PlaceSearchTexts(
    hintText: 'Ort suchen...',
    searchFailed: 'Suche fehlgeschlagen',
    place: 'Ort',
    mountainPeak: 'Berg',
    water: 'Gewässer',
    street: 'Straße',
    near: 'bei',
    decimalSeparator: ',',
  );

  /// Bezeichnung für [GeocoderResult.type]; unbekannte Typen bleiben roh.
  String typeLabel(String type) => switch (type) {
    'place' => place,
    'poi' => poi,
    'mountain_peak' => mountainPeak,
    'water_name' => water,
    'transportation_name' => street,
    _ => type,
  };
}

/// Extensions for GeocoderResult to provide type labels and sorting priority
extension GeocoderResultExtension on GeocoderResult {
  /// Englische Bezeichnung des Typs, siehe [PlaceSearchTexts.typeLabel].
  String get typeLabel => const PlaceSearchTexts().typeLabel(type);

  /// Get type priority for sorting (lower = higher priority), siehe
  /// [GeocoderResult.searchRank].
  int get typePriority => searchRank;
}

class PlaceSearchBar extends StatefulWidget {
  final MapController mapController;
  final PlaceSearch geocoder;
  final double initialZoom;

  /// Überschreibt [PlaceSearchTexts.hintText], etwa für getrennte Start- und
  /// Zielfelder.
  final String? hintText;
  final PlaceSearchTexts texts;
  final IconData prefixIcon;
  final VoidCallback? onClearSearch;
  final Future<List<GeocoderResult>> Function(String query, int limit)?
  searchDelegate;
  final ValueChanged<GeocoderResult>? onPlaceSelected;
  final ValueChanged<GeocoderResult>? onSuggestionPointerDown;
  final void Function(MapController controller, GeocoderResult result)?
  moveToResult;

  /// Die Position, nach der die Treffer sortiert werden - die nahen zuerst,
  /// sonst ist unter tausend Hauptstraßen die eigene kaum zu finden. Liefert
  /// sie `null` oder fehlt sie, gilt die Kartenmitte.
  final LatLng? Function()? nearPosition;

  const PlaceSearchBar({
    super.key,
    required this.mapController,
    required this.geocoder,
    this.initialZoom = 14,
    this.hintText,
    this.texts = const PlaceSearchTexts(),
    this.prefixIcon = Icons.location_on,
    this.onClearSearch,
    this.searchDelegate,
    this.onPlaceSelected,
    this.onSuggestionPointerDown,
    this.moveToResult,
    this.nearPosition,
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
  LatLng? _near;
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
      final near = widget.nearPosition?.call() ?? _mapCenter();
      final found =
          await (widget.searchDelegate?.call(query, 15) ??
              widget.geocoder.searchPlaces(query, limit: 15, near: near));

      // Keine eigene Sortierung: PlaceSearch liefert die wichtigsten Treffer
      // zuerst, nach Typ, Genauigkeit und Nähe. Eine Sortierung hier kennt
      // nur den Typ und würfe das durcheinander.

      if (mounted) {
        setState(() {
          _near = near;
          _suggestions = found;
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
          SnackBar(content: Text('${widget.texts.searchFailed}: $e')),
        );
      }
    }
  }

  LatLng? _mapCenter() {
    try {
      return widget.mapController.camera.center;
    } catch (_) {
      // Die Karte ist noch nicht gezeichnet, es gibt keine Kamera.
      return null;
    }
  }

  /// "Straße · Alsfeld · 3,2 km" - Typ, Ort und Entfernung, damit sich
  /// gleichnamige Treffer unterscheiden lassen.
  String _subtitle(GeocoderResult result) {
    final parts = <String>[widget.texts.typeLabel(result.type)];
    if (result.type == 'poi' && result.detail != null) {
      parts.add(result.detail!);
    }
    final area = result.area;
    if (area != null) {
      parts.add(result.type == 'place' ? '${widget.texts.near} $area' : area);
    }
    final near = _near;
    if (near != null) {
      parts.add(_formatDistance(const Distance()(near, result.location)));
    }
    return parts.join(' · ');
  }

  String _formatDistance(double meters) {
    if (meters < 1000) return '${(meters / 10).round() * 10} m';
    if (meters < 10000) {
      final km = (meters / 1000).toStringAsFixed(1);
      return '${km.replaceAll('.', widget.texts.decimalSeparator)} km';
    }
    return '${(meters / 1000).round()} km';
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
              hintText: widget.hintText ?? widget.texts.hintText,
              prefixIcon: Icon(widget.prefixIcon),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _suggestions = [];
                          _showSuggestions = false;
                        });
                        widget.onClearSearch?.call();
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
          // Material statt einer farbigen Box: ListTile zeichnet Hintergrund
          // und Tintenwelle auf das naechste Material darunter. In einer
          // DecoratedBox waeren sie unsichtbar, Flutter 3.47 meldet das.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Material(
              color: Colors.white,
              elevation: 3,
              shadowColor: Colors.black.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
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
                                _subtitle(result),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => _selectPlace(result),
                            ),
                          );
                        },
                      ),
              ),
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
