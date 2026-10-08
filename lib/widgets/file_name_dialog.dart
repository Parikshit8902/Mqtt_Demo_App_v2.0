import 'package:flutter/material.dart';
import '../services/metrics/metrics_store.dart';

/// Default name offered in the dialog, e.g. experiment_20261008_1403.
String defaultExperimentFileName([DateTime? now]) {
  final t = now ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return 'experiment_${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}';
}

/// Asks the user what to call the exported file. Returns the cleaned name
/// (no extension, no path characters), or null if they cancel.
Future<String?> askFileName(
  BuildContext context, {
  String title = 'Save experiment metrics',
  String? initial,
}) async {
  final controller = TextEditingController(text: initial ?? defaultExperimentFileName());

  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'File name',
          helperText: 'The extension (.txt / .csv / .json) is added for you',
        ),
        onSubmitted: (v) => Navigator.of(ctx).pop(MetricsStore.safeFileName(v)),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(MetricsStore.safeFileName(controller.text)),
          child: const Text('Save'),
        ),
      ],
    ),
  );

  controller.dispose();
  return result;
}
