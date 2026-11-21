String _two(int v) => v.toString().padLeft(2, '0');

/// A time of day as the app's clock setting shows it: 18:05, or 6:05 PM.
String clockText(DateTime t, bool h24, {bool seconds = false}) {
  final rest = '${_two(t.minute)}${seconds ? ':${_two(t.second)}' : ''}';
  if (h24) return '${_two(t.hour)}:$rest';
  return '${t.hour % 12 == 0 ? 12 : t.hour % 12}:$rest ${t.hour < 12 ? 'AM' : 'PM'}';
}
