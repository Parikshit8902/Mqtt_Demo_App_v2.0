import 'dart:async';
import 'dart:typed_data';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

/// Lightweight wrapper around the ultralytics_yolo API so other services
/// (for example `ClientWarmupService`) can call a stable inference callback
/// without depending on UI implementation details.
class InferenceService {
  final String modelPath;
  final bool useGpu;
  final int selectedCores;

  YOLO? _yolo;

  InferenceService({
    required this.modelPath,
    this.useGpu = true,
    this.selectedCores = 1,
  });

  /// Load the model into memory. Safe to call multiple times; it will be a no-op
  /// if already loaded.
  Future<void> loadModel() async {
    if (_yolo != null) return;
    _yolo = YOLO(modelPath: modelPath, task: YOLOTask.detect);
    await _yolo!.loadModel();
  }

  /// Perform a single prediction. Returns the raw map returned by the plugin.
  /// The caller is free to ignore the returned map if only timing matters.
  Future<Map<String, dynamic>> predict(List<int> imageBytes) async {
    if (_yolo == null) {
      await loadModel();
    }
    final u8 = Uint8List.fromList(imageBytes);
    final res = await _yolo!.predict(u8);
    // The plugin returns a dynamic map-like object; ensure we return a Map<String, dynamic>
    return Map<String, dynamic>.from(res as Map);
  }

  /// Convenience helper that returns a `Future<void> Function(List<int>)`
  /// suitable to pass directly into `ClientWarmupService.runWarmup`.
  Future<void> Function(List<int>) makeCallback() {
    return (List<int> bytes) async {
      await predict(bytes);
    };
  }

  /// Dispose the underlying model if needed.
  Future<void> dispose() async {
    // ultralytics_yolo does not currently expose an explicit dispose method,
    // but clearing the reference allows GC and prevents accidental reuse.
    _yolo = null;
  }
}
