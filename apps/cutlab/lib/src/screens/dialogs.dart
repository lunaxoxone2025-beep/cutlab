import 'package:flutter/material.dart';

/// Small text-input dialog. Returns null when cancelled.
Future<String?> promptText(BuildContext context, {required String title, String initial = ''}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _PromptDialog(title: title, initial: initial),
  );
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({required this.title, required this.initial});
  final String title;
  final String initial;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          key: const Key('promptField'),
          controller: _c,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const Key('promptOk'), onPressed: () => Navigator.pop(context, _c.text), child: const Text('OK')),
        ],
      );
}
