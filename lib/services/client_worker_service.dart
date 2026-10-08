import 'dart:async';
// ...existing code...
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'message_logger.dart';
import 'assignments_client.dart';
import 'models/assignment.dart';
import 'models/result_dto.dart';
import 'inference_service.dart';
import 'utils/metrics.dart';
import 'metrics/metrics_store.dart';
import 'metrics/traffic_counter.dart';
import 'performance_service.dart';
import 'utils/idle_wait.dart';

class ClientWorkerService extends ChangeNotifier {
  final MessageLogger _logger;
  final AssignmentsClient _assignClient;
  final InferenceService _inferenceService;

  bool _running = false;
  bool _didWork = false; // processed units since the last report upload
  DateTime _lastReportPush = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _reportPushEvery = Duration(seconds: 30);
  String jobId;
  String clientId;

  // While the host has no work, polls back off from 2 s to 16 s. The host
  // announces new work over MQTT (see nudge), which cuts the wait short.
  final IdleBackoff _idle = IdleBackoff();
  final WakeableDelay _delay = WakeableDelay();

  // This worker's hold on keeping the screen on; per instance, so a worker
  // that is replaced and stops late cannot release its successor's hold.
  late final String _runName = 'worker@${identityHashCode(this)}';

  ClientWorkerService(this._logger, this._assignClient, this._inferenceService, {required this.jobId, required this.clientId});

  bool get isRunning => _running;

  /// The host announced that work is available: ask now instead of waiting
  /// out the idle backoff.
  void nudge() {
    _idle.reset();
    _delay.wake();
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    notifyListeners();
    // Keeps the screen on and the metrics sampling for the whole run.
    PerformanceService.instance.beginRun(_runName);
    MetricsStore.instance.setLocalIdentity(deviceKeyFromClientId(clientId), deviceNameFromClientId(clientId));
    _logger.log('🚧 Client worker started for job $jobId');
    // Ensure model is loaded
    try {
      await _inferenceService.loadModel();
    } catch (e) {
      _logger.log('❌ Could not load the model, worker not started: $e');
      _running = false;
      PerformanceService.instance.endRun(_runName);
      notifyListeners();
      return;
    }

    while (_running) {
      try {
        final assignment = await _assignClient.requestNext(jobId, clientId);
        if (assignment == null || assignment.units.isEmpty) {
          if (_didWork) {
            // Work just ran dry: hand the host this phone's full recording.
            _didWork = false;
            await pushMetricsReport();
          }
          final wait = _idle.next();
          _logger.log('ℹ️ No assignments available, next check in ${wait.inSeconds}s');
          await _delay.sleep(wait);
          continue;
        }
        _idle.reset();

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
              TrafficCounter.instance.countTxMsg(TrafficChannel.httpData); // the GET request
              TrafficCounter.instance.countRxMsg(TrafficChannel.httpData); // the image response
              // Run inference on bytes
              final sw = Stopwatch()..start();
              final Map<String, dynamic> inferRes;
              try {
                inferRes = await _inferenceService.predict(bytes);
              } catch (e) {
                // Not a result: an empty detection list would count as a
                // completed unit and skew both accuracy and timing.
                _logger.log('⚠️ Inference error for unit ${unit.unitIndex}: $e');
                await _reportFailure(unit, 'inference: $e');
                continue;
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

              // Keep the host's copy of this phone's recording (2 s samples, traffic
              // and message counts) fresh while it works, not only when it finishes.
              if (DateTime.now().difference(_lastReportPush) > _reportPushEvery) {
                _lastReportPush = DateTime.now();
                await pushMetricsReport();
              }
            } else {
              _logger.log('❌ Failed to download unit ${unit.unitIndex}: ${streamed.statusCode}');
              await _reportFailure(unit, 'download: HTTP ${streamed.statusCode}');
            }
          } catch (e) {
            _logger.log('❌ Error downloading/processing unit ${unit.unitIndex}: $e');
            await _reportFailure(unit, 'download or processing: $e');
          }
        }
      } catch (e) {
        _logger.log('❌ Worker loop error: $e');
        await _delay.sleep(const Duration(seconds: 2));
      }
    }

    PerformanceService.instance.endRun(_runName);
    _logger.log('🛑 Client worker stopped');
    notifyListeners();
  }

  /// Tell the host this unit could not be processed, so it goes back to the
  /// pool now instead of after its lease runs out. Nothing is recorded as a
  /// finished unit, so the failure stays out of timing and accuracy. If the
  /// host cannot be reached either, the lease still reclaims the unit.
  Future<void> _reportFailure(Unit unit, String reason) async {
    final error = reason.length > 200 ? reason.substring(0, 200) : reason;
    final ok = await _assignClient.postResult(ResultReport(
      jobId: jobId,
      clientId: clientId,
      unitIndex: unit.unitIndex,
      ttprocMs: 0,
      bandwidthKbps: 0,
      error: error,
      health: PerformanceService.instance.currentHealth,
    ));
    _logger.log(ok
        ? '↩️ Reported unit ${unit.unitIndex} as failed ($error)'
        : '⚠️ Could not report unit ${unit.unitIndex} as failed; the host re-queues it when its lease expires');
    // Keeps a phone whose model or link is broken from spinning through the
    // queue; the host stops giving it work after a few failures.
    await Future.delayed(const Duration(seconds: 1));
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
    // An idle worker would otherwise sleep out its backoff before exiting.
    _delay.wake();
  }
}
