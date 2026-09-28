import 'package:http/http.dart' as http;
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'message_logger.dart';
import 'inference_service.dart';
import 'utils/metrics.dart';

class WarmupResult {
  final double ttprocMs;
  final double bandwidthKBps;

  WarmupResult({required this.ttprocMs, required this.bandwidthKBps});
}

/// A simple client warm-up service. The `inferenceCallback` should accept
/// a List<int> of bytes for one image and return a Future<void> that completes
/// when inference finishes. The warmup downloads the warmupUrl (small bundle)
/// and times both download and N inferences to produce ttproc and bandwidth.
class ClientWarmupService {
  final MessageLogger _logger;
  ClientWarmupService(this._logger);

  InferenceService? _internalInference;

  /// Run warmup: download warmupUrl (or range), run N inferences via callback.
  /// inferenceCallback should process image bytes and return when done.
  /// Original callback-based API
  Future<WarmupResult?> runWarmup(String warmupUrl, Future<void> Function(List<int>) inferenceCallback, {int samples = 5}) async {
    try {
      _logger.log('🔁 Warmup: downloading $warmupUrl');
      final stopwatch = Stopwatch()..start();
      final resp = await http.get(Uri.parse(warmupUrl));
      stopwatch.stop();
      if (resp.statusCode != 200) {
        _logger.log('⚠️ Warmup download failed with status ${resp.statusCode}');
        return null;
      }

      final bytes = resp.bodyBytes;
      // If the warmup bundle is a ZIP, try to extract a first compatible image
      List<int> imageBytes = bytes;
      try {
        if (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04) {
          _logger.log('📦 Warmup bundle appears to be a ZIP archive — attempting to extract first image');
          final archive = ZipDecoder().decodeBytes(bytes);
          // Find first file with an image extension
          final imgFile = archive.files.firstWhere(
            (f) => !f.isFile ? false : (f.name.toLowerCase().endsWith('.jpg') || f.name.toLowerCase().endsWith('.jpeg') || f.name.toLowerCase().endsWith('.png') || f.name.toLowerCase().endsWith('.bmp') || f.name.toLowerCase().endsWith('.webp')),
            orElse: () => ArchiveFile('', 0, null),
          );
          if (imgFile.name.isNotEmpty && imgFile.content != null) {
            imageBytes = (imgFile.content as List<int>).toList();
            _logger.log('✅ Extracted image ${imgFile.name} (${imageBytes.length} bytes) from warmup ZIP');
          } else {
            _logger.log('⚠️ No image file found in ZIP; will attempt inference on raw bundle bytes');
          }
        }
      } catch (e) {
        _logger.log('⚠️ Error extracting ZIP warmup bundle: $e — falling back to raw bytes');
      }

    final seconds = stopwatch.elapsedMilliseconds / 1000.0;
    final kBps = computeBandwidthKbpsFromSeconds(bytes.length, seconds);
    _logger.log('\ud83d\udcf6 Warmup download ${bytes.length} bytes in ${seconds}s -> ${kBps.toStringAsFixed(1)} kB/s');

      // For simplicity, treat the warmup bundle as containing images concatenated or single image.
      // We'll run inferenceCallback `samples` times on the same bytes (caller can choose to pass a bundle).
      // Warm-up inference: one warm run then timed runs
      try {
        await inferenceCallback(imageBytes); // warm run (use extracted image if available)
      } catch (e) {
        _logger.log('⚠️ Warm-up inference warm-run failed: $e');
      }

      final sw = Stopwatch()..start();
      for (int i = 0; i < samples; i++) {
        await inferenceCallback(imageBytes);
      }
      sw.stop();
      final totalMs = sw.elapsedMilliseconds;
      final ttprocMs = totalMs / samples;
      _logger.log('⏱️ Warmup inference: $samples samples total ${totalMs}ms -> ${ttprocMs.toStringAsFixed(1)} ms/sample');

      return WarmupResult(ttprocMs: ttprocMs, bandwidthKBps: kBps);
    } catch (e) {
      _logger.log('❌ Warmup failed: $e');
      return null;
    }
  }
}

// New convenience API: provide a modelPath and the warmup will create an
// internal InferenceService and use it for timing. This is useful for in-app
// clients that already have a local model file path.
extension ClientWarmupServiceWithModel on ClientWarmupService {
  Future<WarmupResult?> runWarmupWithModel(String warmupUrl, String modelPath, {int samples = 5}) async {
    _internalInference ??= InferenceService(modelPath: modelPath);
    final callback = _internalInference!.makeCallback();
    final res = await runWarmup(warmupUrl, callback, samples: samples);
    return res;
  }
}
