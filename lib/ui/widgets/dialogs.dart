import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Asks for a line of text. Returns null when cancelled.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  String action = 'Save',
  bool secret = false,
  bool number = false,
}) =>
    showDialog<String>(
      context: context,
      builder: (context) =>
          _TextPrompt(title: title, initial: initial, hint: hint, action: action, secret: secret, number: number),
    );

class _TextPrompt extends StatefulWidget {
  const _TextPrompt({
    required this.title,
    required this.initial,
    required this.hint,
    required this.action,
    this.secret = false,
    this.number = false,
  });
  final String title;
  final String initial;
  final String hint;
  final String action;

  /// Hides what is typed (codes and passwords).
  final bool secret;
  final bool number;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(hintText: widget.hint),
          obscureText: widget.secret,
          enableSuggestions: !widget.secret,
          autocorrect: !widget.secret,
          keyboardType: widget.number ? TextInputType.number : null,
          textCapitalization: widget.secret ? TextCapitalization.none : TextCapitalization.sentences,
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, _controller.text.trim()), child: Text(widget.action)),
        ],
      );
}

Future<bool> confirm(BuildContext context, {required String title, required String body, String action = 'Delete'}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body, style: NType.body(14, color: context.palette.textDim)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: KJPalette.danger, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Picks one option from a list in a bottom sheet.
Future<T?> pickOne<T>(BuildContext context,
    {required String title, required List<T> options, required String Function(T) label, IconData Function(T)? icon}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(title, style: NType.display(24, color: context.palette.text)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final o in options)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                      leading: icon == null ? null : Icon(icon(o)),
                      title: Text(label(o)),
                      onTap: () => Navigator.pop(context, o),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    ),
  );
}

/// Picks several options from a list in a bottom sheet. Returns null when cancelled.
Future<Set<T>?> pickMany<T>(BuildContext context,
    {required String title,
    required List<T> options,
    required String Function(T) label,
    String Function(T)? subtitle,
    IconData Function(T)? icon,
    Set<T> initial = const {},
    String action = 'Done'}) {
  return showModalBottomSheet<Set<T>>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _PickMany<T>(
        title: title, options: options, label: label, subtitle: subtitle, icon: icon, initial: initial, action: action),
  );
}

class _PickMany<T> extends StatefulWidget {
  const _PickMany(
      {required this.title,
      required this.options,
      required this.label,
      required this.subtitle,
      required this.icon,
      required this.initial,
      required this.action});
  final String title;
  final List<T> options;
  final String Function(T) label;
  final String Function(T)? subtitle;
  final IconData Function(T)? icon;
  final Set<T> initial;
  final String action;

  @override
  State<_PickMany<T>> createState() => _PickManyState<T>();
}

class _PickManyState<T> extends State<_PickMany<T>> {
  late final Set<T> _picked = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 12, 8),
              child: Row(children: [
                Expanded(child: Text(widget.title, style: NType.display(24, color: p.text))),
                TextButton(
                  onPressed: () => setState(() =>
                      _picked.length == widget.options.length ? _picked.clear() : _picked.addAll(widget.options)),
                  child: Text(_picked.length == widget.options.length ? 'None' : 'All'),
                ),
              ]),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final o in widget.options)
                    CheckboxListTile(
                      key: Key('pick-${widget.label(o)}'),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                      secondary: widget.icon == null ? null : Icon(widget.icon!(o)),
                      title: Text(widget.label(o)),
                      subtitle: widget.subtitle == null ? null : Text(widget.subtitle!(o)),
                      value: _picked.contains(o),
                      activeColor: KJPalette.accent,
                      onChanged: (v) => setState(() => v == true ? _picked.add(o) : _picked.remove(o)),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
              child: FilledButton(
                key: const Key('pick-done'),
                onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, _picked),
                child: Text('${widget.action} (${_picked.length})'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
