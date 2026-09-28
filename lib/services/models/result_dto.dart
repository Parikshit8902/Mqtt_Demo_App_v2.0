class ResultReport {
  final String jobId;
  final String clientId;
  final int unitIndex;
  final int ttprocMs;
  final double bandwidthKbps;
  final List<dynamic>? detections;
  final String? resultUri;
  final bool warmup;

  ResultReport({
    required this.jobId,
    required this.clientId,
    required this.unitIndex,
    required this.ttprocMs,
    required this.bandwidthKbps,
    this.detections,
    this.resultUri,
    this.warmup = false,
  });

  Map<String, dynamic> toJson() => {
        'j': jobId,
        'i': clientId,
        'unit_index': unitIndex,
        'ttproc_ms': ttprocMs,
        'bandwidth_kBps': bandwidthKbps,
        'detections': detections,
        'result_uri': resultUri,
        'warmup': warmup,
      };

  static ResultReport fromJson(Map<String, dynamic> j) => ResultReport(
        jobId: j['j'] as String,
        clientId: j['i'] as String,
        unitIndex: j['unit_index'] as int,
        ttprocMs: j['ttproc_ms'] as int,
        bandwidthKbps: (j['bandwidth_kBps'] as num).toDouble(),
        detections: (j['detections'] as List<dynamic>?)?.toList(),
        resultUri: j['result_uri'] as String?,
        warmup: j['warmup'] as bool? ?? false,
      );
}

class ClientEstimate {
  double ttprocMs; // ms per unit
  double bandwidthKbps; // kB/s

  ClientEstimate({required this.ttprocMs, required this.bandwidthKbps});
}
