import 'message_logger.dart';
import 'models/assignment.dart';
import 'models/result_dto.dart';
import 'utils/http_helper.dart';

class AssignmentsClient {
  final MessageLogger _logger;
  final String serverBase; // e.g. http://host:8080

  AssignmentsClient(this._logger, {required this.serverBase});

  Future<PerClientAssignment?> fetchAssignmentForClient(String jobId, String clientId) async {
    try {
      final url = Uri.parse('$serverBase/assignments/$jobId/for/$clientId');
      final j = await httpGetJson(url);
      if (j is Map<String, dynamic>) return PerClientAssignment.fromJson(j);
    } catch (e) {
      _logger.log('⚠️ fetchAssignmentForClient error: $e');
    }
    return null;
  }

  Future<PerClientAssignment?> requestNext(String jobId, String clientId) async {
    try {
      final url = Uri.parse('$serverBase/assignments/$jobId/next?for=$clientId');
      final j = await httpGetJson(url);
      _logger.log('🔁 requestNext resp for $clientId on $jobId: got ${j != null}');
      if (j is Map<String, dynamic>) return PerClientAssignment.fromJson(j);
    } catch (e) {
      _logger.log('⚠️ requestNext error: $e');
    }
    return null;
  }

  Future<bool> postResult(ResultReport rr) async {
    try {
      final url = Uri.parse('$serverBase/assignments/${rr.jobId}/results');
      await httpPostJson(url, rr.toJson());
      return true;
    } catch (e) {
      _logger.log('⚠️ postResult error: $e');
    }
    return false;
  }
}
