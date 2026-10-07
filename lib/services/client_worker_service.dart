import 'dart:async';
// ...existing code...
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'message_logger.dart';
import 'assignments_client.dart';
import 'models/result_dto.dart';
import 'inference_service.dart';
import 'utils/metrics.dart';
import 'metrics/metrics_store.dart';
import 'metrics/traffic_counter.dart';
import 'performance_service.dart';

class ClientWorkerService extends ChangeNotifier {
  final MessageLogger _logger;
  final AssignmentsClient _assignClient;
  final InferenceService _inferenceService;

  bool _running = false;
  bool _didWork = false; // processed units since the last report upload
  String jobId;
  String clientId;

  ClientWorkerService(this._logger, this._assignClient, this._inferenceService, {required this.jobId, required this.clientId});

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    notifyListeners();
    MetricsStore.instance.setLocalIdentity(deviceKeyFromClientId(clientId), deviceNameFromClientId(clientId));
    _logger.log('🚧 Client worker started for job $jobId');
    // Ensure model is loaded
    await _inferenceService.loadModel();

    while (_running) {
      try {
        final assignment = await _assignClient.requestNext(jobId, clientId);
        if (assignment == null || assignment.units.isEmpty) {
          if (_didWork) {
            // Work just ran dry: hand the host this phone's full recording.
            _didWork = false;
            await pushMetricsReport();
          }
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
            // Time the download on its own: this is what the scheduler needs as the
            // phone's link speed. (It used to be derived from inference time.)
            final unitSw = Stopwatch()..start();
            final dlSw = Stopwatch()..start();
            final streamed = await req.send();
            if (streamed.statusCode == 200 || streamed.statusCode == 206) {
              final bytes = await streamed.stream.toBytes();
              dlSw.stop();
              TrafficCounter.instance.addRx(TrafficChannel.httpData, bytes.length);
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
              // Effective download throughput (includes request latency and the host's
              // time to produce the bytes, which is what a scheduler should plan with).
              final dlMs = dlSw.elapsedMilliseconds < 1 ? 1 : dlSw.elapsedMilliseconds;
              final bwKbps = computeBandwidthKbpsFromMs(bytes.length, dlMs);
              final totalMs = unitSw.elapsedMilliseconds;

              final detections = inferRes['boxes'] ?? inferRes['detections'] ?? [];
              // Health rides along with the result so the host sees the phone's state at the
              // moment it finished, which is fresher than the 5 s MQTT sample.
              final rr = ResultReport(jobId: jobId, clientId: clientId, unitIndex: unit.unitIndex, ttprocMs: ttMs, bandwidthKbps: bwKbps, bytes: bytes.length, downloadMs: dlMs, totalMs: totalMs, detections: (detections as List<dynamic>?), resultUri: null, warmup: false, health: PerformanceService.instance.currentHealth);
              MetricsStore.instance.recordUnit(
                deviceKeyFromClientId(clientId),
                UnitRecord(
                  deviceKey: deviceKeyFromClientId(clientId),
                  jobId: jobId,
                  unitIndex: unit.unitIndex,
                  bytes: bytes.length,
                  downloadMs: dlMs,
                  inferMs: ttMs,
                  totalMs: totalMs,
                  downloadKBps: bwKbps,
                  scheduler: '',
                  t: DateTime.now().millisecondsSinceEpoch,
                ),
              );
              _didWork = true;
              final ok = await _assignClient.postResult(rr);
              if (ok) {
                _logger.log('✅ Posted result for unit ${unit.unitIndex} (infer=${ttMs}ms download=${dlMs}ms bw=${bwKbps.toStringAsFixed(1)}kB/s)');
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

  /// Upload this phone's full recording (2 s samples, per-unit records, traffic
  /// breakdown) to the host so it can be exported alongside every other phone.
  Future<bool> pushMetricsReport() async {
    final ok = await _assignClient.postMetricsReport(MetricsStore.instance.localReport());
    _logger.log(ok ? '📊 Uploaded metrics report to host' : '⚠️ Failed to upload metrics report');
    return ok;
  }

  void stop() {
    _running = false;
  }
}
