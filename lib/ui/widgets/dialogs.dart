import 'package:flutter/material.dart';

import '../../theme/nothing_theme.dart';

/// Asks for a line of text. Returns null when cancelled.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  String action = 'Save',
}) =>
    showDialog<String>(
      context: context,
      builder: (context) => _TextPrompt(title: title, initial: initial, hint: hint, action: action),
    );

class _TextPrompt extends StatefulWidget {
  const _TextPrompt({required this.title, required this.initial, required this.hint, required this.action});
  final String title;
  final String initial;
  final String hint;
  final String action;

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
          textCapitalization: TextCapitalization.sentences,
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
          style: FilledButton.styleFrom(backgroundColor: NothingPalette.red, foregroundColor: Colors.white),
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
              child: Text(title, style: NType.dot(24, color: context.palette.text)),
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
