/// Dauer, Entfernung und Ankunftszeit so, wie ein Mensch sie im Auto liest.
///
/// Die Bibliothek liefert Sekunden und Meter; das Formatieren gehört zum
/// Gastgeber, weil er die Sprache kennt. Diese hier sind deutsch.
library;

/// "35 min", "4 h 49 min", "2 h" - nie "289 min".
String formatDuration(num seconds) {
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '${minutes < 1 ? 1 : minutes} min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours h' : '$hours h $rest min';
}

/// "350 m", "3,2 km", "498 km". Über 10 km ist die Nachkommastelle nur
/// Rauschen.
String formatDistance(num meters) {
  final rounded = (meters / 10).round() * 10;
  if (rounded < 1000) return '$rounded m';
  if (meters < 10000) {
    return '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
  }
  return '${(meters / 1000).round()} km';
}

/// "Ankunft 22:20", über Mitternacht "Ankunft morgen 00:15", weiter weg
/// mit Datum. [now] nur für Tests.
String formatArrival(num remainingSeconds, {DateTime? now}) {
  final start = now ?? DateTime.now();
  final at = start.add(Duration(seconds: remainingSeconds.round()));
  final time =
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';
  final days = DateTime(
    at.year,
    at.month,
    at.day,
  ).difference(DateTime(start.year, start.month, start.day)).inDays;
  return switch (days) {
    0 => 'Ankunft $time',
    1 => 'Ankunft morgen $time',
    _ => 'Ankunft ${at.day}.${at.month}. $time',
  };
}
