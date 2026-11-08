import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../integrations/weather.dart';
import '../../l10n/text.dart';
import '../../models/home.dart';
import '../../state/app_settings.dart';
import '../../state/home_store.dart';
import '../../state/weather.dart';
import '../../theme/app_theme.dart';
import '../../util/clock_text.dart';
import '../../util/sun.dart';
import '../widgets/alive.dart';
import '../widgets/kj_widgets.dart';

/// The weather at the home, after asking for its town when it has none.
Future<void> showWeatherSheet(BuildContext context) async {
  final store = context.read<HomeStore>();
  if (store.data.place == null && await pickPlace(context) == null) return;
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => const WeatherSheet(),
  );
}

/// Asks which town the home is in, and keeps it. Null when nothing was picked.
Future<HomePlace?> pickPlace(BuildContext context) => showModalBottomSheet<HomePlace>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => const PlaceSearch(),
    );

/// "12° · Cloudy".
String weatherLine(Weather w) => '${w.temp.round()}° · ${tr(w.text)}';

class PlaceSearch extends StatefulWidget {
  const PlaceSearch({super.key});

  @override
  State<PlaceSearch> createState() => _PlaceSearchState();
}

class _PlaceSearchState extends State<PlaceSearch> {
  final _query = TextEditingController();
  Timer? _wait;
  List<HomePlace> _found = const [];
  bool _searching = false;
  String? _problem;
  int _asked = 0;

  @override
  void dispose() {
    _wait?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _typed(String q) {
    _wait?.cancel();
    _wait = Timer(const Duration(milliseconds: 350), () => _search(q));
  }

  Future<void> _search(String q) async {
    final ask = ++_asked;
    if (q.trim().length < 2) {
      setState(() {
        _found = const [];
        _problem = null;
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final found = await context.read<HomeStore>().weather.api.search(q, language: L10n.code);
      if (!mounted || ask != _asked) return;
      setState(() {
        _found = found;
        _problem = found.isEmpty ? 'No town by that name.' : null;
      });
    } catch (e) {
      if (!mounted || ask != _asked) return;
      setState(() {
        _found = const [];
        _problem = e is WeatherException ? e.message : 'The town search did not answer. Is the internet on?';
      });
    } finally {
      if (mounted && ask == _asked) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final store = context.read<HomeStore>();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const DisplayText('Where is your home?', size: 28),
            const SizedBox(height: 6),
            Text('Your town gives the home screen its weather, and scenes and automations their sunrise and sunset.',
                style: NType.body(14, color: p.textDim)),
            const SizedBox(height: 14),
            TextField(
              key: const Key('place-search'),
              controller: _query,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _typed,
              onSubmitted: _search,
              decoration: InputDecoration(
                hintText: tr('Town or city'),
                prefixIcon: const Icon(CupertinoIcons.search),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 8),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                child: Text(_problem!, key: const Key('place-problem'), style: NType.body(14, color: p.textDim)),
              ),
            Expanded(
              child: ListView(children: [
                for (var i = 0; i < _found.length; i++)
                  ListTile(
                    key: Key('place-$i'),
                    leading: const Icon(CupertinoIcons.location_solid, color: KJPalette.accent),
                    title: Text(_found[i].name),
                    subtitle: _found[i].region.isEmpty ? null : Text(_found[i].region),
                    onTap: () {
                      store.setPlace(_found[i]);
                      Navigator.pop(context, _found[i]);
                    },
                  ),
              ]),
            ),
            Text('Town search and weather by Open-Meteo.',
                textAlign: TextAlign.center, style: NType.label(color: p.textDim)),
          ]),
        ),
      ),
    );
  }
}

class WeatherSheet extends StatelessWidget {
  const WeatherSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final weather = context.watch<HomeWeather>();
    final h24 = context.select<AppSettings, bool>((s) => s.clock24);
    final p = context.palette;
    final place = store.data.place;
    final w = weather.now;
    final now = clock.now();
    final today = w?.days.where((d) => _sameDay(d.date, now)).firstOrNull;
    final sun = place == null ? null : SunTimes.on(now, place.lat, place.lon);
    final rise = today?.sunrise ?? sun?.rise?.toLocal();
    final set = today?.sunset ?? sun?.set?.toLocal();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        key: const Key('weather-sheet'),
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                DisplayText(place?.name ?? 'Weather', size: 30, maxLines: 1),
                if (place != null && place.region.isNotEmpty)
                  Text(place.region, style: NType.body(14, color: p.textDim)),
              ]),
            ),
            TextButton(
              key: const Key('weather-change'),
              onPressed: () => pickPlace(context),
              child: const Text('Change town'),
            ),
          ]),
          const SizedBox(height: 18),
          if (w == null)
            NCard(
              child: Row(children: [
                if (weather.loading)
                  const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  Icon(CupertinoIcons.cloud, color: p.textDim),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(weather.loading ? 'Asking for the weather…' : (weather.problem ?? 'No weather yet.'),
                      key: const Key('weather-problem'), style: NType.body(15, color: p.text)),
                ),
                if (!weather.loading)
                  TextButton(
                    key: const Key('weather-retry'),
                    onPressed: () => weather.refresh(place, force: true),
                    child: const Text('Try again'),
                  ),
              ]),
            )
          else ...[
            Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              WeatherGlyph(code: w.code, day: w.day, size: 64, color: _tint(w.code, w.day)),
              const SizedBox(width: 18),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  DisplayText('${w.temp.round()}°', key: const Key('weather-temp'), size: 64, weight: 600),
                  Text(w.text, style: NType.body(18, color: p.text, weight: 600)),
                ]),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
                [
                  trf('Feels like {0}°', ['${w.feelsLike.round()}']),
                  if (today != null) trf('High {0}° · Low {1}°', ['${today.high.round()}', '${today.low.round()}']),
                ].join(' · '),
                style: NType.body(15, color: p.textDim)),
            const SectionLabel('Next hours'),
            NCard(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: SizedBox(
                height: 104,
                child: ListView(
                  key: const Key('weather-hours'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  children: [
                    for (final (i, h) in w.next(now).indexed)
                      SizedBox(
                        width: 58,
                        child: Column(children: [
                          Text(i == 0 ? tr('Now') : _hour(h.at, h24),
                              style: NType.body(13, color: p.textDim, weight: 500)),
                          const SizedBox(height: 8),
                          Icon(Weather.iconOf(h.code, day: h.day), size: 22, color: _tint(h.code, h.day)),
                          const SizedBox(height: 4),
                          Text((h.rain ?? 0) >= 20 ? '${h.rain}%' : ' ',
                              style: NType.body(11, color: KJPalette.accent, weight: 600)),
                          const SizedBox(height: 2),
                          Text('${h.temp.round()}°', style: NType.body(15, color: p.text, weight: 600)),
                        ]),
                      ),
                  ],
                ),
              ),
            ),
            const SectionLabel('Next days'),
            NCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(children: [
                for (final d in w.days.take(7)) _DayRow(day: d, now: now, low: _min(w.days), high: _max(w.days)),
              ]),
            ),
          ],
          const SectionLabel('Today'),
          Row(children: [
            Expanded(
              child: _Fact(
                icon: CupertinoIcons.sunrise_fill,
                label: 'Sunrise',
                value: rise == null ? '–' : clockText(rise, h24),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Fact(
                icon: CupertinoIcons.sunset_fill,
                label: 'Sunset',
                value: set == null ? '–' : clockText(set, h24),
              ),
            ),
          ]),
          if (w != null) ...[
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: _Fact(
                  icon: CupertinoIcons.drop_fill,
                  label: 'Humidity',
                  value: w.humidity == null ? '–' : '${w.humidity!.round()}%',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Fact(
                    icon: CupertinoIcons.wind, label: 'Wind', value: w.wind == null ? '–' : '${w.wind!.round()} km/h'),
              ),
            ]),
          ],
          const SizedBox(height: 16),
          Text('Scenes and automations can run at sunrise or sunset, when it rains, or when it gets hot or cold outside.',
              style: NType.body(13, color: p.textDim)),
          const SizedBox(height: 8),
          Text('Weather by Open-Meteo.', style: NType.label(color: p.textDim)),
        ],
      ),
    );
  }

  /// "18", or "6 PM".
  static String _hour(DateTime t, bool h24) =>
      h24 ? t.hour.toString().padLeft(2, '0') : clockText(t, false).replaceFirst(':00', '');

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
  static double _min(List<WeatherDay> d) => d.take(7).map((e) => e.low).fold(double.infinity, math.min);
  static double _max(List<WeatherDay> d) => d.take(7).map((e) => e.high).fold(-double.infinity, math.max);
}

/// The colour of a weather icon: the sun yellow, rain blue, storms purple, the rest grey.
Color _tint(int code, bool day) {
  if (code <= 1) return day ? KJPalette.orange : KJPalette.indigo;
  if (code == 2) return day ? KJPalette.yellow : KJPalette.indigo;
  if (code >= 95) return KJPalette.purple;
  if (Weather.isWet(code)) return KJPalette.accent;
  if (code >= 71 && code <= 86) return KJPalette.teal;
  return const Color(0xFF8E8E93);
}

class _DayRow extends StatelessWidget {
  const _DayRow({required this.day, required this.now, required this.low, required this.high});
  final WeatherDay day;
  final DateTime now;
  final double low;
  final double high;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isToday = day.date.year == now.year && day.date.month == now.month && day.date.day == now.day;
    final span = (high - low).abs() < 1 ? 1.0 : high - low;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(children: [
        SizedBox(
          width: 64,
          child: Text(isToday ? tr('Today') : weekdayShort(day.date.weekday),
              style: NType.body(15, color: p.text, weight: 600)),
        ),
        SizedBox(
          width: 60,
          child: Row(children: [
            Icon(Weather.iconOf(day.code), size: 20, color: _tint(day.code, true)),
            if ((day.rain ?? 0) >= 30) ...[
              const SizedBox(width: 2),
              Flexible(
                child: Text('${day.rain}%',
                    maxLines: 1, softWrap: false, style: NType.body(10.5, color: KJPalette.accent, weight: 600)),
              ),
            ],
          ]),
        ),
        SizedBox(
          width: 38,
          child: Text('${day.low.round()}°', textAlign: TextAlign.right, style: NType.body(15, color: p.textDim)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final from = (day.low - low) / span * c.maxWidth;
            final to = (day.high - low) / span * c.maxWidth;
            return Container(
              height: 6,
              decoration: BoxDecoration(color: p.border, borderRadius: BorderRadius.circular(3)),
              alignment: Alignment.centerLeft,
              child: Container(
                margin: EdgeInsets.only(left: from.clamp(0, c.maxWidth)),
                width: (to - from).clamp(6, c.maxWidth),
                height: 6,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [KJPalette.teal, KJPalette.yellow, KJPalette.orange]),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            );
          }),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 38,
          child: Text('${day.high.round()}°', style: NType.body(15, color: p.text, weight: 600)),
        ),
      ]),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return NCard(
      padding: const EdgeInsets.all(14),
      child: Row(children: [
        Icon(icon, color: KJPalette.orange, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: NType.body(12.5, color: p.textDim)),
            Text(value, style: NType.body(17, color: p.text, weight: 600)),
          ]),
        ),
      ]),
    );
  }
}
