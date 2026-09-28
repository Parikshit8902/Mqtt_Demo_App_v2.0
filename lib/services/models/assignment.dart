// Simple DTOs for assignment units and per-client assignments
class Unit {
  final int unitIndex;
  final int start; // byte start
  final int end; // byte end
  final String fileUrl;

  Unit({required this.unitIndex, required this.start, required this.end, required this.fileUrl});

  Map<String, dynamic> toJson() => {
        'unit_index': unitIndex,
        'start': start,
        'end': end,
        'file_url': fileUrl,
      };

  static Unit fromJson(Map<String, dynamic> j) => Unit(
        unitIndex: j['unit_index'] as int,
        start: j['start'] as int,
        end: j['end'] as int,
        fileUrl: j['file_url'] as String,
      );
}

class PerClientAssignment {
  final String jobId;
  final String clientId;
  final List<Unit> units;

  PerClientAssignment({required this.jobId, required this.clientId, required this.units});

  Map<String, dynamic> toJson() => {
        'job_id': jobId,
        'client_id': clientId,
        'units': units.map((u) => u.toJson()).toList(),
      };

  static PerClientAssignment fromJson(Map<String, dynamic> j) => PerClientAssignment(
        jobId: j['job_id'] as String,
        clientId: j['client_id'] as String,
        units: (j['units'] as List<dynamic>).map((e) => Unit.fromJson(e as Map<String, dynamic>)).toList(),
      );
}
