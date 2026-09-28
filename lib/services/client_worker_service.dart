import 'dart:async';
// ...existing code...
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'message_logger.dart';
import 'assignments_client.dart';
import 'models/result_dto.dart';
import 'inference_service.dart';
import 'utils/metrics.dart';

class ClientWorkerService extends ChangeNotifier {
  final MessageLogger _logger;
  final AssignmentsClient _assignClient;
  final InferenceService _inferenceService;

  bool _running = false;
  String jobId;
  String clientId;

  ClientWorkerService(this._logger, this._assignClient, this._inferenceService, {required this.jobId, required this.clientId});

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    notifyListeners();
    _logger.log('🚧 Client worker started for job $jobId');
    // Ensure model is loaded
    await _inferenceService.loadModel();

    while (_running) {
      try {
        final assignment = await _assignClient.requestNext(jobId, clientId);
        if (assignment == null || assignment.units.isEmpty) {
          _logger.log('ℹ️ No assignments available, sleeping 2s');
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }

        for (final unit in assignment.units) {
          if (!_running) break;
          _logger.log('⬇️ Downloading unit ${unit.unitIndex} bytes ${unit.start}-${unit.end} from ${unit.fileUrl}');
          try {
            final uri = Uri.parse(unit.fileUrl);
            final req = http.Request('GET', uri);
            // If this unit references a zip entry (has ?entry=) or is the full file (start==0 && end==0 meaning unknown),
            // avoid using Range header so server can return 200 with full content. Use Range only when non-zero ranges are required.
            final hasEntry = uri.queryParameters.containsKey('entry');
            final needsRange = !hasEntry && !(unit.start == 0 && unit.end == 0);
            if (needsRange) {
              req.headers['Range'] = 'bytes=${unit.start}-${unit.end}';
            }
            final streamed = await req.send();
            if (streamed.statusCode == 200 || streamed.statusCode == 206) {
              final bytes = await streamed.stream.toBytes();
              // Run inference on bytes
              final sw = Stopwatch()..start();
              Map<String, dynamic> inferRes = {};
              try {
                inferRes = await _inferenceService.predict(bytes);
              } catch (e) {
                _logger.log('⚠️ Inference error for unit ${unit.unitIndex}: $e');
              }
              sw.stop();
              final ttMs = sw.elapsedMilliseconds;
              // For bandwidth estimate, use helper
              final bwKbps = computeBandwidthKbpsFromMs(bytes.length, ttMs);

              final detections = inferRes['boxes'] ?? inferRes['detections'] ?? [];
              final rr = ResultReport(jobId: jobId, clientId: clientId, unitIndex: unit.unitIndex, ttprocMs: ttMs, bandwidthKbps: bwKbps, detections: (detections as List<dynamic>?), resultUri: null, warmup: false);
              final ok = await _assignClient.postResult(rr);
              if (ok) {
                _logger.log('✅ Posted result for unit ${unit.unitIndex} (tt=${ttMs}ms bw=${bwKbps.toStringAsFixed(1)}kB/s)');
              } else {
                _logger.log('⚠️ Failed to post result for unit ${unit.unitIndex}');
              }
            } else {
              _logger.log('❌ Failed to download unit ${unit.unitIndex}: ${streamed.statusCode}');
            }
          } catch (e) {
            _logger.log('❌ Error downloading/processing unit ${unit.unitIndex}: $e');
          }
        }
      } catch (e) {
        _logger.log('❌ Worker loop error: $e');
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    _logger.log('🛑 Client worker stopped');
    notifyListeners();
  }

  void stop() {
    _running = false;
  }
}
