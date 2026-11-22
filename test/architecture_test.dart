// Rules that keep the code apart, so a fix in one place cannot break another:
//
// 1. Only lib/platform/ may ask which system the app runs on. A Mac fix goes in lib/platform/macos.dart and a
//    Windows fix in lib/platform/windows.dart, so neither can change the other.
// 2. The back end (models, state, integrations, cloud, util) never uses screens or widgets, so a change to how
//    something looks cannot break how devices are controlled. Icons are allowed: they are only data.
//
// When one of these fails, the message says which file and line, and where the code belongs instead.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<File> _dart(String dir) =>
    Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));

String _rel(File f) => f.path.replaceAll(r'\', '/');

void main() {
  test('only lib/platform/ checks which system the app runs on', () {
    final ask = RegExp(r'\bPlatform\.(is[A-Z]\w*|operatingSystem\w*|localHostname|version)\b|defaultTargetPlatform\s*==');
    final found = <String>[];
    for (final f in _dart('lib')) {
      final path = _rel(f);
      if (path.startsWith('lib/platform/')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (ask.hasMatch(lines[i])) found.add('$path:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(found, isEmpty,
        reason: 'Ask AppPlatform.current instead, and put what differs in lib/platform/<system>.dart:\n'
            '${found.join('\n')}');
  });

  test('the back end does not use screens or widgets', () {
    final ui = RegExp(r'''^import\s+'(package:flutter/(material|widgets|cupertino)\.dart|[./]*ui/[^']*)'(.*);''');
    // Icons are data; a background start needs the binding. Anything else from Flutter's widgets is screen code.
    final allowed = RegExp(r'^\s*show\s+((IconData|Icons|CupertinoIcons|WidgetsFlutterBinding|debugPrint)\s*,?\s*)+$');
    final found = <String>[];
    for (final dir in ['lib/models', 'lib/state', 'lib/integrations', 'lib/cloud', 'lib/util']) {
      for (final f in _dart(dir)) {
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final m = ui.firstMatch(lines[i].trim());
          if (m == null) continue;
          if (!m.group(1)!.contains('ui/') && allowed.hasMatch(m.group(3)!)) continue;
          found.add('${_rel(f)}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(found, isEmpty,
        reason: 'Back-end code must not depend on screens. Move the screen part into lib/ui/:\n${found.join('\n')}');
  });

  test('screens do not talk to devices directly', () {
    // Screens go through HomeStore; drivers and sockets belong to the back end.
    final direct = RegExp(r'\b(Socket|RawDatagramSocket|HttpClient)\.(connect|bind)\b');
    final found = <String>[];
    for (final f in _dart('lib/ui')) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (direct.hasMatch(lines[i])) found.add('${_rel(f)}:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(found, isEmpty, reason: 'Do this in lib/integrations/ or HomeStore:\n${found.join('\n')}');
  });
}
