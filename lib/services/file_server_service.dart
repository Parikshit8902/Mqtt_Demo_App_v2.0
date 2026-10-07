import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';
import 'package:archive/archive.dart';
import 'message_logger.dart';
import 'distribution_singleton.dart';
import 'models/result_dto.dart';
import 'models/assignment.dart';
import 'network_helper.dart';
import 'metrics/metrics_store.dart';
import 'metrics/traffic_counter.dart';
import 'schedulers/scheduler_registry.dart';

/// Manages the HTTP file server for sharing files between devices
class FileServerService {
  final MessageLogger _logger;
  final Function()? _onStateChanged;
  final Map<String, _SharedFile> _sharedFiles = {};
  
  HttpServer? _server;
  bool _isServerRunning = false;
  final int _port = 8080;
  String _serverIp = '';
  String _networkAccessibleIp = '';
  
  FileServerService(this._logger, {Function()? onStateChanged}) 
    : _onStateChanged = onStateChanged;
  
  // Getters
  bool get isServerRunning => _isServerRunning;
  String get serverUrl => 'http://$_serverIp:$_port';
  String get networkServerUrl => 'http://$_networkAccessibleIp:$_port';
  int get serverPort => _port;
  String get serverIp => _serverIp;
  String get networkAccessibleIp => _networkAccessibleIp;
  
  /// Start the HTTP file server
  Future<bool> startServer(String ip) async {
    if (_isServerRunning) {
      _logger.log('📡 File server is already running');
      return true;
    }
    
    _serverIp = ip;
    _logger.log('🚀 Starting HTTP file server...');
    
    try {
      // Get the network-accessible IP address
      _networkAccessibleIp = await _getNetworkAccessibleIp(ip);
      _logger.log('🌐 Network accessible IP: $_networkAccessibleIp');
      
      // Create a router for handling requests
      final router = Router();
      
      // Route for getting file info
      router.get('/files/<fileId>/info', _handleFileInfoRequest);
      
      // Route for downloading files
      router.get('/files/<fileId>', _handleFileDownloadRequest);
      
    // Route for listing available files
    router.get('/files', _handleListFilesRequest);
  // Admin: set job options (e.g. default max units per assignment)
  router.post('/admin/job_options', _handleSetJobOptions);
  // Admin endpoints for warmup reporting
  router.post('/admin/warmup', _handleWarmupReport);
  router.get('/admin/warmup', _handleWarmupStatus);
  // Job status endpoint
  router.get('/admin/job_status', _handleJobStatus);
  // Scheduler logs endpoint
  router.get('/admin/scheduler_logs', _handleSchedulerLogs);
  // Assignment endpoints for distributed jobs
  router.get('/assignments/<jobId>/for/<clientId>', _handleGetAssignmentForClient);
  router.get('/assignments/<jobId>/next', _handleGetNextAssignment);
  router.post('/assignments/<jobId>/results', _handlePostResultReport);
  // Metrics: workers upload their full recording; anyone on the LAN can pull the
  // combined results (e.g. open http://<host-ip>:8080/admin/metrics.csv in a browser).
  router.post('/admin/metrics_report', _handleMetricsReport);
  router.get('/admin/metrics', _handleMetricsJson);
  router.get('/admin/metrics.csv', _handleMetricsCsv);
  // Scheduling algorithm selection
  router.get('/admin/scheduler', _handleGetScheduler);
  router.post('/admin/scheduler', _handleSetScheduler);
      
      // Create a shelf handler with logging
      final logMiddleware = shelf.logRequests();
      MetricsStore.instance.schedulerId = distributionManager.schedulerId;
      final handler = shelf.Pipeline()
          .addMiddleware(logMiddleware)
          .addMiddleware(_trafficMiddleware())
          .addHandler(router.call);
      
      // Start the server - bind to any IPv4 address to ensure it's accessible from the network
      _logger.log('🔧 Creating HTTP server on 0.0.0.0:$_port (accessible via $_networkAccessibleIp)');
      _server = await shelf_io.serve(
        handler,
        InternetAddress.anyIPv4, // Bind to any address so it's accessible from the network
        _port,
        shared: true,
      );
      
      _isServerRunning = true;
      _logger.log('✅ HTTP file server started on $_networkAccessibleIp:$_port');
      if (_onStateChanged != null) {
        _onStateChanged();
      }
      return true;
    } catch (e) {
      _logger.log('❌ Failed to start HTTP file server: $e');
      return false;
    }
  }
  
  /// Get the network-accessible IP address
  Future<String> _getNetworkAccessibleIp(String ip) async {
    // If the IP is already a valid network IP (not localhost), use it
    if (ip != '127.0.0.1' && ip != 'localhost') {
      return ip;
    }
    
    // Try to get the device's IP address
    final deviceIp = await NetworkHelper.getDeviceIPAddress();
    if (deviceIp != null) {
      _logger.log('🔍 Found device IP: $deviceIp');
      return deviceIp;
    }
    
    // If we can't find a valid IP, default to the input IP
    _logger.log('⚠️ Could not determine network IP, using: $ip');
    return ip;
  }
  
  /// Stop the HTTP file server
  Future<void> stopServer() async {
    _logger.log('🛑 Stopping HTTP file server...');
    
    try {
      if (_server != null) {
        await _server!.close(force: true);
        _server = null;
      }
      
      _isServerRunning = false;
      _sharedFiles.clear();
      _logger.log('✅ HTTP file server stopped');
      if (_onStateChanged != null) {
        _onStateChanged();
      }
    } catch (e) {
      _logger.log('❌ Error stopping HTTP file server: $e');
    }
  }
  
  /// Share a file and get a unique URL for it
  Future<FileShareInfo?> shareFile(File file) async {
    // Clear previous shared files so only the latest file is available
    _sharedFiles.clear();
    if (!_isServerRunning) {
      _logger.log('❌ Cannot share file - server not running');
      return null;
    }
    
    try {
      final fileId = const Uuid().v4();
      final fileName = path.basename(file.path);
      final fileSize = await file.length();
      final fileExtension = path.extension(file.path).toLowerCase();
      final mimeType = _getMimeType(fileExtension);
      
      _logger.log('📂 Preparing to share file: $fileName');
      _logger.log('📊 File size: ${_formatFileSize(fileSize)}');
      
      // Store file information
      _sharedFiles[fileId] = _SharedFile(
        id: fileId,
        file: file,
        name: fileName,
        size: fileSize,
        mimeType: mimeType,
        dateAdded: DateTime.now(),
      );
      
      final url = '$serverUrl/files/$fileId';
      _logger.log('🔗 File available at: $url');
      
      return FileShareInfo(
        fileId: fileId,
        fileName: fileName,
        fileSize: fileSize,
        mimeType: mimeType,
        url: url,
      );
    } catch (e) {
      _logger.log('❌ Error sharing file: $e');
      return null;
    }
  }
  
  /// Handle file info request
  Future<shelf.Response> _handleFileInfoRequest(shelf.Request request, String fileId) async {
    _logger.log('📝 File info requested for ID: $fileId');
    
    if (!_sharedFiles.containsKey(fileId)) {
      _logger.log('❌ File not found: $fileId');
      return shelf.Response.notFound('File not found');
    }
    
    final sharedFile = _sharedFiles[fileId]!;
    
    return shelf.Response.ok(
      jsonEncode({
        'id': sharedFile.id,
        'name': sharedFile.name,
        'size': sharedFile.size,
        'mimeType': sharedFile.mimeType,
        'dateAdded': sharedFile.dateAdded.toIso8601String(),
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }
  
  /// Handle file download request
  Future<shelf.Response> _handleFileDownloadRequest(shelf.Request request, String fileId) async {
    _logger.log('📥 File download requested for ID: $fileId');
    
    if (!_sharedFiles.containsKey(fileId)) {
      _logger.log('❌ File not found: $fileId');
      return shelf.Response.notFound('File not found');
    }
    
    final sharedFile = _sharedFiles[fileId]!;
    final file = sharedFile.file;
    // Support serving a specific entry from a ZIP via ?entry=<name>
    final entryParam = request.url.queryParameters['entry'];
    if (entryParam != null && entryParam.isNotEmpty && (sharedFile.mimeType == 'application/zip' || sharedFile.name.toLowerCase().endsWith('.zip'))) {
      try {
        final entryName = Uri.decodeComponent(entryParam);
        final bytes = await file.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        final af = archive.files.firstWhere((f) => f.name == entryName, orElse: () => ArchiveFile('', 0, null));
        if (af.name.isEmpty || af.content == null) {
          _logger.log('❌ Entry not found in archive: $entryName');
          return shelf.Response.notFound('Entry not found');
        }
        final entryBytes = (af.content as List<int>);
        // Range support for entry bytes
        final rangeHeader = request.headers['range'];
        if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
          final parts = rangeHeader.substring(6).split('-');
          int start = int.parse(parts[0]);
          int end = parts.length > 1 && parts[1].isNotEmpty ? int.parse(parts[1]) : entryBytes.length - 1;
          if (end >= entryBytes.length) end = entryBytes.length - 1;
          final chunk = entryBytes.sublist(start, end + 1);
          return shelf.Response(206, body: Stream.fromIterable([chunk]), headers: {
            'Content-Type': _getMimeType(path.extension(af.name).toLowerCase()),
            'Content-Length': chunk.length.toString(),
            'Content-Range': 'bytes $start-$end/${entryBytes.length}',
            'Content-Disposition': 'attachment; filename="${af.name}"',
            'Accept-Ranges': 'bytes',
            'Cache-Control': 'no-cache, no-store, must-revalidate',
            'Pragma': 'no-cache',
            'Expires': '0',
          });
        }

        return shelf.Response.ok(Stream.fromIterable([entryBytes]), headers: {
          'Content-Type': _getMimeType(path.extension(af.name).toLowerCase()),
          'Content-Length': entryBytes.length.toString(),
          'Content-Disposition': 'attachment; filename="${af.name}"',
          'Accept-Ranges': 'bytes',
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'Pragma': 'no-cache',
          'Expires': '0',
        });
      } catch (e) {
        _logger.log('❌ Error serving zip entry: $e');
        return shelf.Response.internalServerError(body: 'error');
      }
    }
    
    // Check if range request (for resumable downloads)
    final rangeHeader = request.headers['range'];
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      return _handleRangeRequest(rangeHeader, file, sharedFile);
    }
    
    _logger.log('📤 Serving complete file: ${sharedFile.name}');
    
    // Add cache control headers to prevent caching issues with large files
    return shelf.Response.ok(
      file.openRead(),
      headers: {
        'Content-Type': sharedFile.mimeType,
        'Content-Length': sharedFile.size.toString(),
        'Content-Disposition': 'attachment; filename="${sharedFile.name}"',
        'Accept-Ranges': 'bytes',
        'Cache-Control': 'no-cache, no-store, must-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0',
      },
    );
  }
  
  /// Handle range request for resumable downloads
  Future<shelf.Response> _handleRangeRequest(String rangeHeader, File file, _SharedFile sharedFile) async {
    final range = rangeHeader.substring(6);
    final parts = range.split('-');
    
    int start = int.parse(parts[0]);
    int end = parts.length > 1 && parts[1].isNotEmpty 
        ? int.parse(parts[1]) 
        : sharedFile.size - 1;
    
    // Ensure end is not greater than file size
    if (end >= sharedFile.size) {
      end = sharedFile.size - 1;
    }
    
    // Limit chunk size to prevent memory issues with large files
    const maxChunkSize = 5 * 1024 * 1024; // 5MB max chunk
    if (end - start > maxChunkSize) {
      end = start + maxChunkSize - 1;
    }
    
    final length = end - start + 1;
    
    _logger.log('📤 Serving partial file: ${sharedFile.name}, bytes $start-$end/${sharedFile.size}');
    
    return shelf.Response(
      206,
      body: file.openRead(start, end + 1),
      headers: {
        'Content-Type': sharedFile.mimeType,
        'Content-Length': length.toString(),
        'Content-Range': 'bytes $start-$end/${sharedFile.size}',
        'Content-Disposition': 'attachment; filename="${sharedFile.name}"',
        'Accept-Ranges': 'bytes',
        'Cache-Control': 'no-cache, no-store, must-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0',
      },
    );
  }
  
  /// Handle list files request
  Future<shelf.Response> _handleListFilesRequest(shelf.Request request) async {
    _logger.log('📋 File list requested');
    
    // Extract the Host header from the request to use client's perspective URL
    final requestHost = request.headers['host'];
    String baseUrl;
    
    if (requestHost != null) {
      // Use the host header from the client's request
      baseUrl = 'http://$requestHost';
      _logger.log('🌐 Using client-provided host header: $requestHost');
    } else {
      // Fallback to our network IP if host header is not available
      baseUrl = 'http://$_networkAccessibleIp:$_port';
      _logger.log('⚠️ No host header, using network IP: $_networkAccessibleIp:$_port');
    }
    
    _logger.log('🌐 Using base URL for response: $baseUrl');
    
    final files = _sharedFiles.values.map((file) => {
      'id': file.id,
      'name': file.name,
      'size': file.size,
      'mimeType': file.mimeType,
      'dateAdded': file.dateAdded.toIso8601String(),
      'url': '$baseUrl/files/${file.id}',
    }).toList();
    
    return shelf.Response.ok(
      jsonEncode(files),
      headers: {'Content-Type': 'application/json'},
    );
  }

  // In-memory store for warmup reports keyed by client id
  final Map<String, Map<String, dynamic>> _warmupReports = {};
  // In-memory scheduler logs (most recent first)
  final List<Map<String, dynamic>> _schedulerLogs = [];
  // In-memory result reports keyed by job id (most recent first)
  final Map<String, List<Map<String, dynamic>>> _resultReportsByJob = {};
  // per-job default units to assign when clients request next
  final Map<String, int> _jobDefaultUnits = {};

  /// Handle warmup reports posted by clients
  Future<shelf.Response> _handleWarmupReport(shelf.Request request) async {
    try {
      final body = await request.readAsString();
      final Map<String, dynamic> j = jsonDecode(body);
      final clientId = j['client_id'] as String? ?? 'unknown';
      _warmupReports[clientId] = j;
      _logger.log('📥 Warmup report received from $clientId: $j');

      // Seed distribution manager with this client's estimate
      try {
        final tt = (j['ttproc_ms'] as num?)?.toDouble() ?? 0.0;
        final bw = (j['bandwidth_kBps'] as num?)?.toDouble() ?? 0.0;
        distributionManager.registerClient(clientId, ClientEstimate(ttprocMs: tt, bandwidthKbps: bw));
        _logger.log('🔧 Registered client $clientId in DistributionManager with tt=$tt ms, bw=$bw kB/s');

        // If there are no units for the demo job, register a small demo job so we can show scheduling results
        try {
          final prog = distributionManager.jobProgress('demo_job');
          final totalUnits = (prog['total'] is int) ? prog['total'] as int : int.tryParse('${prog['total']}') ?? 0;
          if (totalUnits == 0) {
            // Prefer a recently shared dataset (zip / coco) to create units from
            _logger.log('🔍 Looking for a shared dataset to create demo_job units');
            _SharedFile? datasetFile;
            try {
              datasetFile = _sharedFiles.values.toList().reversed.firstWhere((f) => f.mimeType == 'application/zip' || f.name.toLowerCase().contains('coco'), orElse: () => _SharedFile(id: '', file: File(''), name: '', size: 0, mimeType: '', dateAdded: DateTime.now()));
              if (datasetFile.id == '') datasetFile = null;
            } catch (_) {
              datasetFile = null;
            }

            List<Unit> jobUnits = [];
            if (datasetFile != null && datasetFile.size > 0) {
              _logger.log('🧾 Using shared dataset ${datasetFile.name} (${_formatFileSize(datasetFile.size)}) for demo_job');
              // If the shared dataset is a ZIP, enumerate image entries and create one unit per image.
              if (datasetFile.mimeType == 'application/zip' || datasetFile.name.toLowerCase().endsWith('.zip')) {
                try {
                  final bytes = await datasetFile.file.readAsBytes();
                  final archive = ZipDecoder().decodeBytes(bytes);
                  final imageFiles = archive.files.where((f) => f.isFile && (f.name.toLowerCase().endsWith('.jpg') || f.name.toLowerCase().endsWith('.jpeg') || f.name.toLowerCase().endsWith('.png') || f.name.toLowerCase().endsWith('.bmp') || f.name.toLowerCase().endsWith('.webp'))).toList();
                  if (imageFiles.isNotEmpty) {
                    int idx = 0;
                    for (final af in imageFiles) {
                      final entryName = af.name;
                      final entrySize = af.size;
                      final fileUrl = '$networkServerUrl/files/${datasetFile.id}?entry=${Uri.encodeComponent(entryName)}';
                      jobUnits.add(Unit(unitIndex: idx++, start: 0, end: entrySize > 0 ? entrySize - 1 : 0, fileUrl: fileUrl));
                    }
                  } else {
                    _logger.log('⚠️ No image entries found inside ZIP; falling back to chunked units of the full file');
                    final int parts = 10;
                    final int chunk = (datasetFile.size / parts).ceil();
                    for (int i = 0; i < parts; i++) {
                      final start = i * chunk;
                      final end = (i == parts - 1) ? datasetFile.size - 1 : ((i + 1) * chunk - 1);
                      final fileUrl = '$networkServerUrl/files/${datasetFile.id}';
                      jobUnits.add(Unit(unitIndex: i, start: start, end: end, fileUrl: fileUrl));
                    }
                  }
                } catch (e) {
                  _logger.log('⚠️ Error reading ZIP to enumerate entries: $e - falling back to chunked units');
                  final int parts = 10;
                  final int chunk = (datasetFile.size / parts).ceil();
                  for (int i = 0; i < parts; i++) {
                    final start = i * chunk;
                    final end = (i == parts - 1) ? datasetFile.size - 1 : ((i + 1) * chunk - 1);
                    final fileUrl = '$networkServerUrl/files/${datasetFile.id}';
                    jobUnits.add(Unit(unitIndex: i, start: start, end: end, fileUrl: fileUrl));
                  }
                }
              } else {
                final fileUrl = '$networkServerUrl/files/${datasetFile.id}';
                final int parts = 10;
                final int chunk = (datasetFile.size / parts).ceil();
                for (int i = 0; i < parts; i++) {
                  final start = i * chunk;
                  final end = (i == parts - 1) ? datasetFile.size - 1 : ((i + 1) * chunk - 1);
                  jobUnits.add(Unit(unitIndex: i, start: start, end: end, fileUrl: fileUrl));
                }
              }
            } else {
              // Fallback to a dummy demo file path
              _logger.log('⚠️ No shared dataset found, falling back to dummy demo file for demo_job');
              jobUnits = List<Unit>.generate(10, (i) => Unit(unitIndex: i, start: i * 1000, end: (i + 1) * 1000 - 1, fileUrl: '${networkServerUrl}/files/demo'));
            }

            final jobId = datasetFile != null && datasetFile.id.isNotEmpty ? datasetFile.id : 'demo_job';
            distributionManager.registerJob(jobId, jobUnits);
            _logger.log('🧪 Registered job $jobId with ${jobUnits.length} units for scheduling demo');
          }
        } catch (e) {
          _logger.log('⚠️ Error checking/creating demo_job: $e');
        }
        // Produce a scheduling suggestion using current client estimates and log the assignments
        try {
          // For each registered client, request assignments and log which units would be given
          final clients = distributionManager.registeredClientIds;
      final suggestionSummary = {'time': DateTime.now().toIso8601String(), 'type': 'suggestion', 'assignments': {}};
          for (final cid in clients) {
            final jobIdForSuggestion = _sharedFiles.values.isNotEmpty ? _sharedFiles.values.toList().reversed.first.id : 'demo_job';
            final assigned = distributionManager.suggestNext(jobIdForSuggestion, cid, maxUnits: 2);
            if (assigned.isNotEmpty) {
              _logger.log('📈 Scheduling suggestion for $cid: ${assigned.map((u) => u.unitIndex).toList()}');
        (suggestionSummary['assignments'] as Map)[cid] = assigned.map((u) => u.unitIndex).toList();
            } else {
              _logger.log('📈 Scheduling suggestion for $cid: none');
        (suggestionSummary['assignments'] as Map)[cid] = [];
            }
          }
      // store recent suggestion
      _schedulerLogs.insert(0, suggestionSummary);
      if (_schedulerLogs.length > 50) _schedulerLogs.removeLast();
        } catch (e) {
          _logger.log('⚠️ Error generating scheduling suggestions: $e');
        }
      } catch (e) {
        _logger.log('⚠️ Error seeding DistributionManager: $e');
      }
      return shelf.Response.ok(jsonEncode({'status': 'ok'}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      _logger.log('❌ Error processing warmup report: $e');
      return shelf.Response.internalServerError(body: 'error');
    }
  }

  /// Return current warmup reports as JSON
  Future<shelf.Response> _handleWarmupStatus(shelf.Request request) async {
    try {
      return shelf.Response.ok(jsonEncode(_warmupReports), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      _logger.log('❌ Error serializing warmup reports: $e');
      return shelf.Response.internalServerError(body: 'error');
    }
  }

  /// Return job status: progress and per-client assigned units
  Future<shelf.Response> _handleJobStatus(shelf.Request request) async {
    try {
      // collect jobs known to distribution manager
      final jobs = <String, dynamic>{};
      try {
        // Note: DistributionManager keeps jobs internally; access via jobProgress and registeredClientIds
        // We'll enumerate registered clients and ask for their queues
        final clients = distributionManager.registeredClientIds;
        for (final cid in clients) {
          final q = distributionManager.getClientQueue(cid);
          jobs[cid] = q.map((u) => {'unitIndex': u.unitIndex, 'fileUrl': u.fileUrl}).toList();
        }
      } catch (_) {}

      // include job progress for demo_job fallback plus any other job ids known via _jobs is internal
      final progress = <String, dynamic>{};
      try {
        // attempt to check a few job ids: demo_job and any shared file ids
        final candidateIds = <String>{'demo_job'};
        candidateIds.addAll(_sharedFiles.keys);
        for (final jid in candidateIds) {
          final p = distributionManager.jobProgress(jid);
          if (p['total'] != 0) progress[jid] = p;
        }
      } catch (_) {}

      final Map<String, dynamic> out = {'per_client_queues': jobs, 'progress': progress};
      final Map<String, dynamic> recent = {};
      try {
        for (final e in _resultReportsByJob.entries) {
          recent[e.key] = e.value;
        }
      } catch (_) {}
      out['recent_results'] = recent;
      return shelf.Response.ok(jsonEncode(out), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      _logger.log('❌ Error generating job status: $e');
      return shelf.Response.internalServerError(body: 'error');
    }
  }

  Future<shelf.Response> _handleSchedulerLogs(shelf.Request request) async {
    try {
      return shelf.Response.ok(jsonEncode(_schedulerLogs), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      _logger.log('❌ Error serializing scheduler logs: $e');
      return shelf.Response.internalServerError(body: 'error');
    }
  }

  /// Return per-client assignment for a job (non-destructive)
  Future<shelf.Response> _handleGetAssignmentForClient(shelf.Request request, String jobId, String clientId) async {
    try {
      final queue = distributionManager.getClientQueue(clientId);
      final assignment = PerClientAssignment(jobId: jobId, clientId: clientId, units: queue);
      return shelf.Response.ok(jsonEncode(assignment.toJson()), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      _logger.log('❌ Error fetching assignment for $clientId on $jobId: $e');
      return shelf.Response.internalServerError(body: 'error');
    }
  }

  /// Request next assignment for a client (will assign using scheduler)
  Future<shelf.Response> _handleGetNextAssignment(shelf.Request request, String jobId) async {
    try {
      final clientId = request.url.queryParameters['for'] ?? 'unknown';
      if (clientId == 'unknown') return shelf.Response(400, body: 'missing client id');
      // determine maxUnits: prefer explicit query param, then job default, then 2
      int maxUnits = 2;
      try {
        final q = request.url.queryParameters['max'];
        if (q != null) maxUnits = int.tryParse(q) ?? maxUnits;
        else if (_jobDefaultUnits.containsKey(jobId)) maxUnits = _jobDefaultUnits[jobId]!;
      } catch (_) {}
      final units = distributionManager.assignNext(jobId, clientId, maxUnits: maxUnits);
      final assignment = PerClientAssignment(jobId: jobId, clientId: clientId, units: units);
      _logger.log('📦 Assigned ${units.length} units to $clientId for job $jobId');
      if (units.isEmpty) {
        // If job does not exist, log clearly
        if (!distributionManager.hasJob(jobId)) {
          _logger.log('⚠️ Request for next assignment: job $jobId not found');
          return shelf.Response.notFound('job_not_found');
        }
        // No units available right now — return progress metadata so clients can see state
        try {
          final prog = distributionManager.jobProgress(jobId);
          final body = jsonEncode({'job_id': jobId, 'client_id': clientId, 'units': [], 'progress': prog});
          return shelf.Response.ok(body, headers: {'Content-Type': 'application/json'});
        } catch (_) {}
      }
      // record assignment in scheduler logs
      try {
        _schedulerLogs.insert(0, {'time': DateTime.now().toIso8601String(), 'type': 'assignment', 'job': jobId, 'client': clientId, 'units': units.map((u) => u.unitIndex).toList()});
        if (_schedulerLogs.length > 50) _schedulerLogs.removeLast();
      } catch (_) {}
      return shelf.Response.ok(jsonEncode(assignment.toJson()), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      _logger.log('❌ Error assigning next units for $jobId: $e');
      return shelf.Response.internalServerError(body: 'error');
    }
  }

  /// Admin: set job options such as default max units per assignment
  Future<shelf.Response> _handleSetJobOptions(shelf.Request request) async {
    try {
      final body = await request.readAsString();
      final j = jsonDecode(body) as Map<String, dynamic>;
      final jobId = j['job_id'] as String?;
      if (jobId == null) return shelf.Response(400, body: 'missing job_id');
      final defaultMax = (j['default_max_units'] is int) ? j['default_max_units'] as int : int.tryParse('${j['default_max_units']}') ?? 0;
      if (defaultMax > 0) {
        _jobDefaultUnits[jobId] = defaultMax;
        _logger.log('⚙️ Set default_max_units for $jobId -> $defaultMax');
        return shelf.Response.ok(jsonEncode({'status': 'ok'}), headers: {'Content-Type': 'application/json'});
      }
      return shelf.Response(400, body: 'invalid default_max_units');
    } catch (e) {
      _logger.log('❌ Error setting job options: $e');
      return shelf.Response.internalServerError(body: 'error');
    }
  }

  /// Receive result reports from clients for job units
  Future<shelf.Response> _handlePostResultReport(shelf.Request request, String jobId) async {
    try {
      final body = await request.readAsString();
      final j = jsonDecode(body) as Map<String, dynamic>;
      final rr = ResultReport.fromJson(j);
  // Mark unit complete and update client estimate
      distributionManager.markUnitComplete(jobId, rr.unitIndex);
      distributionManager.updateClientEstimate(rr.clientId, rr.ttprocMs.toDouble(), rr.bandwidthKbps);
      _logger.log('✅ Result received for job ${rr.jobId} unit ${rr.unitIndex} from ${rr.clientId} (infer=${rr.ttprocMs}ms download=${rr.downloadMs}ms bw=${rr.bandwidthKbps.toStringAsFixed(1)}kB/s)');
      final deviceKey = deviceKeyFromClientId(rr.clientId);
      MetricsStore.instance.recordUnit(
        deviceKey,
        UnitRecord(
          deviceKey: deviceKey,
          jobId: jobId,
          unitIndex: rr.unitIndex,
          bytes: rr.bytes,
          downloadMs: rr.downloadMs,
          inferMs: rr.ttprocMs,
          totalMs: rr.totalMs,
          downloadKBps: rr.bandwidthKbps,
          scheduler: distributionManager.schedulerId,
          t: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      // Produce a quick scheduler summary after receiving result
      try {
        final summary = distributionManager.jobProgress(jobId);
        _logger.log('📊 Job $jobId progress: total=${summary['total']} completed=${summary['completed']} available=${summary['available']}');
  // append to scheduler logs
  _schedulerLogs.insert(0, {'time': DateTime.now().toIso8601String(), 'type': 'progress', 'job': jobId, 'progress': summary});
  if (_schedulerLogs.length > 50) _schedulerLogs.removeLast();
  
  // store recent result for UI inspection
    try {
      final list = _resultReportsByJob.putIfAbsent(jobId, () => <Map<String, dynamic>>[]);
      // attempt to lookup the unit's fileUrl from internal job list for convenience
      String? fileUrl;
      try {
        fileUrl = distributionManager.getUnitFileUrl(jobId, rr.unitIndex);
      } catch (_) {}
      // store with a received timestamp for UI display and include original file URL so host can fetch image
      final entry = <String, dynamic>{'received_at': DateTime.now().toIso8601String(), 'file_url': fileUrl, ...rr.toJson()};
      list.insert(0, entry);
      if (list.length > 200) list.removeLast();
    } catch (_) {}
      } catch (_) {}

      return shelf.Response.ok(jsonEncode({'status': 'ok'}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      _logger.log('❌ Error processing result report: $e');
      return shelf.Response.internalServerError(body: 'error');
    }
  }

  /// Counts every HTTP body byte this phone serves/receives, per peer, so the
  /// host's own network load can be attributed to each worker.
  shelf.Middleware _trafficMiddleware() {
    return (shelf.Handler inner) {
      return (shelf.Request request) async {
        final channel = request.url.path.startsWith('files') ? TrafficChannel.httpData : TrafficChannel.httpControl;
        final info = request.context['shelf.io.connection_info'];
        final peer = info is HttpConnectionInfo ? info.remoteAddress.address : null;
        final counted = request.change(
          body: request.read().map((chunk) {
            TrafficCounter.instance.addRx(channel, chunk.length, peer: peer);
            return chunk;
          }),
        );
        final response = await inner(counted);
        return response.change(
          body: response.read().map((chunk) {
            TrafficCounter.instance.addTx(channel, chunk.length, peer: peer);
            return chunk;
          }),
        );
      };
    };
  }

  /// A worker uploads its full recording (samples, per-unit records, traffic).
  Future<shelf.Response> _handleMetricsReport(shelf.Request request) async {
    try {
      final j = jsonDecode(await request.readAsString());
      if (j is! Map<String, dynamic>) return shelf.Response(400, body: 'expected object');
      MetricsStore.instance.mergeDeviceReport(j);
      _logger.log('📊 Metrics report received from ${j['name']} (${j['key']})');
      return shelf.Response.ok(jsonEncode({'status': 'ok'}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      _logger.log('❌ Error processing metrics report: $e');
      return shelf.Response.internalServerError(body: 'error');
    }
  }

  Future<shelf.Response> _handleMetricsJson(shelf.Request request) async {
    final device = request.url.queryParameters['device'];
    return shelf.Response.ok(
      jsonEncode(MetricsStore.instance.toJson(deviceKey: device)),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// kind = summary (default) | samples | units; optional device=<ip>.
  Future<shelf.Response> _handleMetricsCsv(shelf.Request request) async {
    final store = MetricsStore.instance;
    final device = request.url.queryParameters['device'];
    final kind = request.url.queryParameters['kind'] ?? 'summary';
    final String csv;
    switch (kind) {
      case 'samples':
        csv = store.samplesCsv(deviceKey: device);
        break;
      case 'units':
        csv = store.unitsCsv(deviceKey: device);
        break;
      default:
        csv = store.summaryCsv(deviceKey: device);
    }
    return shelf.Response.ok(csv, headers: {
      'Content-Type': 'text/csv; charset=utf-8',
      'Content-Disposition': 'attachment; filename="metrics_$kind.csv"',
    });
  }

  Future<shelf.Response> _handleGetScheduler(shelf.Request request) async {
    return shelf.Response.ok(
      jsonEncode({
        'active': distributionManager.schedulerId,
        'available': [for (final id in SchedulerRegistry.ids) {'id': id, 'label': SchedulerRegistry.labelFor(id)}],
        'schedule_calls': distributionManager.scheduleCalls,
        'avg_schedule_ms': distributionManager.avgScheduleMs,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// Body: {"id": "round_robin"}
  Future<shelf.Response> _handleSetScheduler(shelf.Request request) async {
    try {
      final j = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final id = j['id'] as String? ?? '';
      if (!SchedulerRegistry.contains(id)) {
        return shelf.Response(400, body: 'unknown scheduler: $id (available: ${SchedulerRegistry.ids.join(', ')})');
      }
      distributionManager.setScheduler(id);
      MetricsStore.instance.schedulerId = id;
      _logger.log('🧭 Scheduler set to $id');
      return shelf.Response.ok(jsonEncode({'status': 'ok', 'active': id}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return shelf.Response(400, body: 'bad request: $e');
    }
  }

  /// Expose warmup reports for UI polling
  Map<String, Map<String, dynamic>> get warmupReports => Map.from(_warmupReports);
  
  /// Get MIME type based on file extension
  String _getMimeType(String extension) {
    switch (extension) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.pdf':
        return 'application/pdf';
      case '.doc':
      case '.docx':
        return 'application/msword';
      case '.xls':
      case '.xlsx':
        return 'application/vnd.ms-excel';
      case '.ppt':
      case '.pptx':
        return 'application/vnd.ms-powerpoint';
      case '.mp3':
        return 'audio/mpeg';
      case '.mp4':
        return 'video/mp4';
      case '.zip':
        return 'application/zip';
      case '.txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }
  
  /// Format file size for display
  String _formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(2)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }
  
  /// Clean up resources
  void dispose() {
    stopServer();
  }
}

/// Information about a shared file
class _SharedFile {
  final String id;
  final File file;
  final String name;
  final int size;
  final String mimeType;
  final DateTime dateAdded;
  
  _SharedFile({
    required this.id,
    required this.file,
    required this.name,
    required this.size,
    required this.mimeType,
    required this.dateAdded,
  });
}

/// File share information for sending via MQTT
class FileShareInfo {
  final String fileId;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final String url;
  
  FileShareInfo({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.url,
  });
  
  Map<String, dynamic> toJson() {
    return {
      'type': 'file_share',
      'fileId': fileId,
      'fileName': fileName,
      'fileSize': fileSize,
      'mimeType': mimeType,
      'url': url,
    };
  }
  
  factory FileShareInfo.fromJson(Map<String, dynamic> json) {
    return FileShareInfo(
      fileId: json['fileId'],
      fileName: json['fileName'],
      fileSize: json['fileSize'],
      mimeType: json['mimeType'],
      url: json['url'],
    );
  }
}
