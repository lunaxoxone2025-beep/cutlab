import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../diagnostics/diagnostics.dart';
import '../services.dart';
import '../theme.dart';

/// Crash reports, device and decoder information, and the engine activity
/// log, with buttons to copy or save everything as one text report.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  late Future<String> _report = _load();

  Diagnostics? get _d => widget.services.diagnostics;

  Future<String> _load() async => await _d?.report() ?? 'Diagnostics are not available in this build.';

  void _reload() => setState(() => _report = _load());

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: await _report));
    _snack('Report copied');
  }

  Future<void> _save() async {
    final text = await _report;
    final name = 'cutlab-diagnostics-${DateTime.now().toIso8601String().split('.').first.replaceAll(':', '-')}.txt';
    try {
      final d = _d;
      if (Platform.isAndroid || d == null) {
        final ok = await widget.services.media.saveProjectFile(name, text);
        if (ok) _snack('Report saved');
      } else {
        final f = File('${d.directory.path}${Platform.pathSeparator}$name');
        await f.writeAsString(text);
        _snack('Report saved to ${f.path}');
      }
    } on Object catch (e) {
      _snack('Could not save the report: $e');
    }
  }

  Future<void> _resetHardware() async {
    await widget.services.media.resetHardwareChecks();
    _snack('Hardware decoding will be tested again for each kind of video');
    _reload();
  }

  Future<void> _clear() async {
    await _d?.clearHistory();
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(key: const Key('copyReport'), tooltip: 'Copy report', icon: const Icon(Icons.copy_all_outlined), onPressed: _copy),
          IconButton(key: const Key('saveReport'), tooltip: 'Save report', icon: const Icon(Icons.save_alt), onPressed: _save),
        ],
      ),
      body: FutureBuilder<String>(
        future: _report,
        builder: (context, snap) {
          final text = snap.data;
          return ListView(
            padding: const EdgeInsets.all(CutlabSpacing.lg),
            children: [
              if (d?.notice != null)
                Card(
                  color: CutlabColors.surfaceRaised,
                  child: Padding(padding: const EdgeInsets.all(CutlabSpacing.md), child: Text(d!.notice!)),
                ),
              const Text(
                'If CUTLAB closes by itself, the next start shows what happened here: the video engine records the '
                'error, the video being decoded (codec, size, hardware or software) and memory use; Android adds its own record. '
                'Copy or save the report to look into it.',
                style: TextStyle(color: CutlabColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: CutlabSpacing.sm),
              Wrap(
                spacing: CutlabSpacing.sm,
                runSpacing: CutlabSpacing.sm,
                children: [
                  OutlinedButton.icon(
                    key: const Key('resetHardwareChecks'),
                    onPressed: _resetHardware,
                    icon: const Icon(Icons.memory),
                    label: const Text('Test hardware decoding again'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('clearHistory'),
                    onPressed: _clear,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Clear crash history'),
                  ),
                ],
              ),
              const SizedBox(height: CutlabSpacing.lg),
              if (text == null)
                const Center(child: CircularProgressIndicator())
              else
                SelectableText(
                  text,
                  key: const Key('diagnosticsReport'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Shown once at start-up when CUTLAB ended abnormally last time.
Future<void> showCrashNotice(BuildContext context, AppServices services) async {
  final d = services.diagnostics;
  if (d == null || d.newCrashes.isEmpty) return;
  final crashes = List<CrashReport>.of(d.newCrashes);
  d.newCrashes.clear();
  final lowMemory = crashes.any((c) => c.lowMemory);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('crashNotice'),
      title: const Text('CUTLAB closed unexpectedly'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final c in crashes.take(3)) Text('• ${c.title} (${c.time.toLocal().toString().split('.').first})'),
            if (lowMemory)
              const Padding(
                padding: EdgeInsets.only(top: CutlabSpacing.sm),
                child: Text('Android stopped CUTLAB because the phone ran low on memory. A lower preview quality in '
                    'Settings uses less memory.'),
              ),
            if (d.notice != null) Padding(padding: const EdgeInsets.only(top: CutlabSpacing.sm), child: Text(d.notice!)),
            const Padding(
              padding: EdgeInsets.only(top: CutlabSpacing.sm),
              child: Text('Your projects are saved. The details are in Settings → Diagnostics.'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
        FilledButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DiagnosticsScreen(services: services)));
          },
          child: const Text('Details'),
        ),
      ],
    ),
  );
}
