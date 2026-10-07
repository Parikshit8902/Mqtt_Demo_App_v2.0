class ResultReport {
  final String jobId;
  final String clientId;
  final int unitIndex;
  final int ttprocMs; // inference time only
  final double bandwidthKbps; // download throughput in kB/s (bytes / download time), despite the name
  final int bytes; // bytes downloaded for this unit
  final int downloadMs; // download time only
  final int totalMs; // download + inference
  final List<dynamic>? detections;
  final String? resultUri;
  final bool warmup;

  ResultReport({
    required this.jobId,
    required this.clientId,
    required this.unitIndex,
    required this.ttprocMs,
    required this.bandwidthKbps,
    this.bytes = 0,
    this.downloadMs = 0,
    this.totalMs = 0,
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
        'bytes': bytes,
        'download_ms': downloadMs,
        'total_ms': totalMs,
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
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        downloadMs: (j['download_ms'] as num?)?.toInt() ?? 0,
        totalMs: (j['total_ms'] as num?)?.toInt() ?? 0,
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
