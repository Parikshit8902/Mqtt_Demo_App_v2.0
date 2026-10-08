import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import 'message_logger.dart';
import 'distribution_manager.dart' show UnitFailureOutcome;
import 'distribution_singleton.dart';
import 'models/result_dto.dart';
import 'models/assignment.dart';
import 'network_helper.dart';
import 'metrics/metrics_store.dart';
import 'experiment_report.dart';
import 'metrics/traffic_counter.dart';
import 'schedulers/scheduler_registry.dart';
import 'utils/zip_entry_cache.dart';

/// Manages the HTTP file server for sharing files between devices.
///
/// In addition to file sharing, this service maintains experiment-specific
/// scheduling/result information and exposes endpoints for:
/// - resetting the current experiment
/// - downloading metrics for the current experiment
class FileServerService {
  final MessageLogger _logger;
  final Function()? _onStateChanged;
  final Map<String, _SharedFile> _sharedFiles = {};

  /// Called with a job id when that job has units to hand out (it was just
  /// registered, or a failed unit went back to the pool), so the host can
  /// tell idle workers to ask now.
  void Function(String jobId)? onWorkAvailable;

  /// Shared ZIPs extracted once, so serving an image is a file read rather
  /// than a full decode of the dataset on every request.
  final ZipEntryCache _zipCache = ZipEntryCache(
    () async => Directory(
      path.join(
        (await getTemporaryDirectory()).path,
        'zip_entry_cache',
      ),
    ),
  );

  HttpServer? _server;
  bool _isServerRunning = false;
  final int _port = 8080;
  String _serverIp = '';
  String _networkAccessibleIp = '';

  FileServerService(
    this._logger, {
    Function()? onStateChanged,
  }) : _onStateChanged = onStateChanged;

  // ---------------------------------------------------------------------------
  // SERVER GETTERS
  // ---------------------------------------------------------------------------

  bool get isServerRunning => _isServerRunning;

  String get serverUrl => 'http://$_serverIp:$_port';

  String get networkServerUrl =>
      'http://$_networkAccessibleIp:$_port';

  int get serverPort => _port;

  String get serverIp => _serverIp;

  String get networkAccessibleIp => _networkAccessibleIp;

  // ---------------------------------------------------------------------------
  // EXPERIMENT-SPECIFIC STATE
  // ---------------------------------------------------------------------------

  /// In-memory store for warmup reports keyed by client id.
  ///
  /// Warmup information is intentionally preserved across experiments because
  /// it represents client/network characteristics rather than experiment
  /// results.
  final Map<String, Map<String, dynamic>> _warmupReports = {};

  /// In-memory scheduler logs for the current experiment.
  ///
  /// These are reset when a new experiment starts.
  final List<Map<String, dynamic>> _schedulerLogs = [];

  /// In-memory result reports for the current experiment.
  ///
  /// Keyed by job id.
  final Map<String, List<Map<String, dynamic>>>
      _resultReportsByJob = {};

  /// Per-job default units to assign when clients request next.
  ///
  /// This is considered configuration rather than experiment-result state,
  /// therefore it is preserved when an experiment is reset.
  final Map<String, int> _jobDefaultUnits = {};

  // ---------------------------------------------------------------------------
  // SERVER MANAGEMENT
  // ---------------------------------------------------------------------------

  /// Start the HTTP file server.
  Future<bool> startServer(String ip) async {
    if (_isServerRunning) {
      _logger.log('📡 File server is already running');
      return true;
    }

    _serverIp = ip;
    _logger.log('🚀 Starting HTTP file server...');

    try {
      // Get the network-accessible IP address.
      _networkAccessibleIp =
          await _getNetworkAccessibleIp(ip);

      _logger.log(
        '🌐 Network accessible IP: $_networkAccessibleIp',
      );

      // Create a router for handling requests.
      final router = Router();

      // -----------------------------------------------------------------------
      // FILE SHARING
      // -----------------------------------------------------------------------

      // Route for getting file info.
      router.get(
        '/files/<fileId>/info',
        _handleFileInfoRequest,
      );

      // Route for downloading files.
      router.get(
        '/files/<fileId>',
        _handleFileDownloadRequest,
      );

      // Route for listing available files.
      router.get(
        '/files',
        _handleListFilesRequest,
      );

      // -----------------------------------------------------------------------
      // ADMIN / EXPERIMENT MANAGEMENT
      // -----------------------------------------------------------------------

      // Set job options such as default max units per assignment.
      router.post(
        '/admin/job_options',
        _handleSetJobOptions,
      );

      // Warmup reporting.
      router.post(
        '/admin/warmup',
        _handleWarmupReport,
      );

      router.get(
        '/admin/warmup',
        _handleWarmupStatus,
      );

      // Job status.
      router.get(
        '/admin/job_status',
        _handleJobStatus,
      );

      // Scheduler logs.
      router.get(
        '/admin/scheduler_logs',
        _handleSchedulerLogs,
      );

      // Reset experiment-specific state.
      router.post(
        '/admin/reset_experiment',
        _handleResetExperiment,
      );

      // Download metrics for the current experiment.
      router.get(
        '/admin/metrics',
        _handleDownloadMetrics,
      );

      // Per-phone metrics: workers upload their full recording; anyone on the
      // LAN can pull the combined results (open
      // http://<host-ip>:8080/admin/metrics.csv in a browser).
      router.post(
        '/admin/metrics_report',
        _handleMetricsReport,
      );

      router.get(
        '/admin/metrics.json',
        _handleMetricsJson,
      );

      router.get(
        '/admin/metrics.csv',
        _handleMetricsCsv,
      );

      // Scheduling algorithm selection (also settable from the host UI).
      router.get(
        '/admin/scheduler',
        _handleGetScheduler,
      );

      router.post(
        '/admin/scheduler',
        _handleSetScheduler,
      );

      // -----------------------------------------------------------------------
      // DISTRIBUTED JOB ENDPOINTS
      // -----------------------------------------------------------------------

      router.get(
        '/assignments/<jobId>/for/<clientId>',
        _handleGetAssignmentForClient,
      );

      router.get(
        '/assignments/<jobId>/next',
        _handleGetNextAssignment,
      );

      router.post(
        '/assignments/<jobId>/results',
        _handlePostResultReport,
      );

      // -----------------------------------------------------------------------
      // SERVER
      // -----------------------------------------------------------------------

      final logMiddleware = shelf.logRequests();

      MetricsStore.instance.schedulerId = distributionManager.schedulerId;

      // Units reclaimed from a phone that stopped answering show up in the
      // host log next to the assignments they affect.
      distributionManager.onLog = _logger.log;

      final handler = shelf.Pipeline()
          .addMiddleware(logMiddleware)
          .addMiddleware(_trafficMiddleware())
          .addHandler(router.call);

      _logger.log(
        '🔧 Creating HTTP server on '
        '0.0.0.0:$_port '
        '(accessible via $_networkAccessibleIp)',
      );

      _server = await shelf_io.serve(
        handler,
        InternetAddress.anyIPv4,
        _port,
        shared: true,
      );

      _isServerRunning = true;

      _logger.log(
        '✅ HTTP file server started on '
        '$_networkAccessibleIp:$_port',
      );

      if (_onStateChanged != null) {
        _onStateChanged();
      }

      return true;
    } catch (e) {
      _logger.log(
        '❌ Failed to start HTTP file server: $e',
      );
      return false;
    }
  }

  /// Get the network-accessible IP address.
  Future<String> _getNetworkAccessibleIp(
    String ip,
  ) async {
    // If the IP is already a valid network IP
    // (not localhost), use it.
    if (ip != '127.0.0.1' &&
        ip != 'localhost') {
      return ip;
    }

    // Try to get the device's IP address.
    final deviceIp =
        await NetworkHelper.getDeviceIPAddress();

    if (deviceIp != null) {
      _logger.log(
        '🔍 Found device IP: $deviceIp',
      );
      return deviceIp;
    }

    // If we can't find a valid IP, default to
    // the input IP.
    _logger.log(
      '⚠️ Could not determine network IP, '
      'using: $ip',
    );

    return ip;
  }

  /// Stop the HTTP file server.
  Future<void> stopServer() async {
    _logger.log(
      '🛑 Stopping HTTP file server...',
    );

    try {
      if (_server != null) {
        await _server!.close(force: true);
        _server = null;
      }

      _isServerRunning = false;
      _sharedFiles.clear();
      await _zipCache.clear();

      _logger.log(
        '✅ HTTP file server stopped',
      );

      if (_onStateChanged != null) {
        _onStateChanged();
      }
    } catch (e) {
      _logger.log(
        '❌ Error stopping HTTP file server: $e',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // FILE SHARING
  // ---------------------------------------------------------------------------

  /// Share a file and get a unique URL for it.
  Future<FileShareInfo?> shareFile(
    File file,
  ) async {
    // Clear previous shared files so only the latest
    // file is available.
    _sharedFiles.clear();
    await _zipCache.clear();

    if (!_isServerRunning) {
      _logger.log(
        '❌ Cannot share file - server not running',
      );
      return null;
    }

    try {
      final fileId = const Uuid().v4();
      final fileName = path.basename(file.path);
      final fileSize = await file.length();
      final fileExtension =
          path.extension(file.path).toLowerCase();
      final mimeType =
          _getMimeType(fileExtension);

      _logger.log(
        '📂 Preparing to share file: $fileName',
      );

      _logger.log(
        '📊 File size: ${_formatFileSize(fileSize)}',
      );

      // Store file information.
      _sharedFiles[fileId] = _SharedFile(
        id: fileId,
        file: file,
        name: fileName,
        size: fileSize,
        mimeType: mimeType,
        dateAdded: DateTime.now(),
      );

      final url =
          '$serverUrl/files/$fileId';

      _logger.log(
        '🔗 File available at: $url',
      );

      return FileShareInfo(
        fileId: fileId,
        fileName: fileName,
        fileSize: fileSize,
        mimeType: mimeType,
        url: url,
      );
    } catch (e) {
      _logger.log(
        '❌ Error sharing file: $e',
      );
      return null;
    }
  }

  /// Handle file info request.
  Future<shelf.Response> _handleFileInfoRequest(
    shelf.Request request,
    String fileId,
  ) async {
    _logger.log(
      '📝 File info requested for ID: $fileId',
    );

    if (!_sharedFiles.containsKey(fileId)) {
      _logger.log(
        '❌ File not found: $fileId',
      );

      return shelf.Response.notFound(
        'File not found',
      );
    }

    final sharedFile =
        _sharedFiles[fileId]!;

    return shelf.Response.ok(
      jsonEncode({
        'id': sharedFile.id,
        'name': sharedFile.name,
        'size': sharedFile.size,
        'mimeType': sharedFile.mimeType,
        'dateAdded':
            sharedFile.dateAdded.toIso8601String(),
      }),
      headers: {
        'Content-Type': 'application/json',
      },
    );
  }

  /// Handle file download request.
  Future<shelf.Response> _handleFileDownloadRequest(
    shelf.Request request,
    String fileId,
  ) async {
    _logger.log(
      '📥 File download requested for ID: $fileId',
    );

    if (!_sharedFiles.containsKey(fileId)) {
      _logger.log(
        '❌ File not found: $fileId',
      );

      return shelf.Response.notFound(
        'File not found',
      );
    }

    final sharedFile =
        _sharedFiles[fileId]!;
    final file = sharedFile.file;

    // Support serving a specific entry from a ZIP
    // via ?entry=<name>.
    final entryParam =
        request.url.queryParameters['entry'];

    if (entryParam != null &&
        entryParam.isNotEmpty &&
        (sharedFile.mimeType ==
                'application/zip' ||
            sharedFile.name
                .toLowerCase()
                .endsWith('.zip'))) {
      try {
        final entryName =
            Uri.decodeComponent(entryParam);

        // Extracted once per shared file; later requests read from disk.
        final entry = await _zipCache.entry(
          fileId,
          file,
          entryName,
        );

        if (entry == null) {
          _logger.log(
            '❌ Entry not found in archive: '
            '$entryName',
          );

          return shelf.Response.notFound(
            'Entry not found',
          );
        }

        final entryFile = File(entry.path);

        // Range support for entry bytes.
        final rangeHeader =
            request.headers['range'];

        if (rangeHeader != null &&
            rangeHeader.startsWith('bytes=')) {
          final parts =
              rangeHeader.substring(6).split('-');

          int start =
              int.parse(parts[0]);

          int end = parts.length > 1 &&
                  parts[1].isNotEmpty
              ? int.parse(parts[1])
              : entry.size - 1;

          if (end >= entry.size) {
            end = entry.size - 1;
          }

          if (start > end) {
            return shelf.Response(
              416,
              headers: {
                'Content-Range':
                    'bytes */${entry.size}',
              },
            );
          }

          return shelf.Response(
            206,
            body: entryFile.openRead(
              start,
              end + 1,
            ),
            headers: {
              'Content-Type': _getMimeType(
                path.extension(
                  entry.name,
                ).toLowerCase(),
              ),
              'Content-Length':
                  (end - start + 1).toString(),
              'Content-Range':
                  'bytes $start-$end/${entry.size}',
              'Content-Disposition':
                  'attachment; filename="${entry.name}"',
              'Accept-Ranges': 'bytes',
              'Cache-Control':
                  'no-cache, no-store, must-revalidate',
              'Pragma': 'no-cache',
              'Expires': '0',
            },
          );
        }

        return shelf.Response.ok(
          entryFile.openRead(),
          headers: {
            'Content-Type': _getMimeType(
              path.extension(
                entry.name,
              ).toLowerCase(),
            ),
            'Content-Length':
                entry.size.toString(),
            'Content-Disposition':
                'attachment; filename="${entry.name}"',
            'Accept-Ranges': 'bytes',
            'Cache-Control':
                'no-cache, no-store, must-revalidate',
            'Pragma': 'no-cache',
            'Expires': '0',
          },
        );
      } catch (e) {
        _logger.log(
          '❌ Error serving zip entry: $e',
        );

        return shelf.Response.internalServerError(
          body: 'error',
        );
      }
    }

    // Check if range request
    // (for resumable downloads).
    final rangeHeader =
        request.headers['range'];

    if (rangeHeader != null &&
        rangeHeader.startsWith('bytes=')) {
      return _handleRangeRequest(
        rangeHeader,
        file,
        sharedFile,
      );
    }

    _logger.log(
      '📤 Serving complete file: '
      '${sharedFile.name}',
    );

    return shelf.Response.ok(
      file.openRead(),
      headers: {
        'Content-Type': sharedFile.mimeType,
        'Content-Length':
            sharedFile.size.toString(),
        'Content-Disposition':
            'attachment; filename="${sharedFile.name}"',
        'Accept-Ranges': 'bytes',
        'Cache-Control':
            'no-cache, no-store, must-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0',
      },
    );
  }

  /// Handle range request for resumable downloads.
  Future<shelf.Response> _handleRangeRequest(
    String rangeHeader,
    File file,
    _SharedFile sharedFile,
  ) async {
    final range =
        rangeHeader.substring(6);

    final parts = range.split('-');

    int start =
        int.parse(parts[0]);

    int end = parts.length > 1 &&
            parts[1].isNotEmpty
        ? int.parse(parts[1])
        : sharedFile.size - 1;

    // Ensure end is not greater than file size.
    if (end >= sharedFile.size) {
      end = sharedFile.size - 1;
    }

    // Limit chunk size to prevent memory issues
    // with large files.
    const maxChunkSize =
        5 * 1024 * 1024;

    if (end - start > maxChunkSize) {
      end =
          start + maxChunkSize - 1;
    }

    final length =
        end - start + 1;

    _logger.log(
      '📤 Serving partial file: '
      '${sharedFile.name}, '
      'bytes $start-$end/${sharedFile.size}',
    );

    return shelf.Response(
      206,
      body: file.openRead(
        start,
        end + 1,
      ),
      headers: {
        'Content-Type':
            sharedFile.mimeType,
        'Content-Length':
            length.toString(),
        'Content-Range':
            'bytes $start-$end/${sharedFile.size}',
        'Content-Disposition':
            'attachment; filename="${sharedFile.name}"',
        'Accept-Ranges': 'bytes',
        'Cache-Control':
            'no-cache, no-store, must-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0',
      },
    );
  }

  /// Handle list files request.
  Future<shelf.Response> _handleListFilesRequest(
    shelf.Request request,
  ) async {
    _logger.log(
      '📋 File list requested',
    );

    // Extract the Host header from the request
    // to use client's perspective URL.
    final requestHost =
        request.headers['host'];

    String baseUrl;

    if (requestHost != null) {
      baseUrl =
          'http://$requestHost';

      _logger.log(
        '🌐 Using client-provided host header: '
        '$requestHost',
      );
    } else {
      baseUrl =
          'http://$_networkAccessibleIp:$_port';

      _logger.log(
        '⚠️ No host header, using network IP: '
        '$_networkAccessibleIp:$_port',
      );
    }

    _logger.log(
      '🌐 Using base URL for response: $baseUrl',
    );

    final files =
        _sharedFiles.values.map(
      (file) => {
        'id': file.id,
        'name': file.name,
        'size': file.size,
        'mimeType': file.mimeType,
        'dateAdded':
            file.dateAdded.toIso8601String(),
        'url':
            '$baseUrl/files/${file.id}',
      },
    ).toList();

    return shelf.Response.ok(
      jsonEncode(files),
      headers: {
        'Content-Type': 'application/json',
      },
    );
  }

  // ---------------------------------------------------------------------------
  // WARMUP
  // ---------------------------------------------------------------------------

  /// Id the current job is registered under: the most recently shared dataset
  /// (zip / coco), or 'demo_job' when none has been shared.
  String _currentJobId() {
    for (final f in _sharedFiles.values.toList().reversed) {
      if (f.mimeType == 'application/zip' ||
          f.name.toLowerCase().contains('coco')) {
        return f.id;
      }
    }

    return 'demo_job';
  }

  /// Handle warmup reports posted by clients.
  Future<shelf.Response> _handleWarmupReport(
    shelf.Request request,
  ) async {
    try {
      final body =
          await request.readAsString();

      final Map<String, dynamic> j =
          jsonDecode(body);

      final clientId =
          j['client_id'] as String? ??
              'unknown';

      _warmupReports[clientId] = j;

      _logger.log(
        '📥 Warmup report received from '
        '$clientId: $j',
      );

      // Seed distribution manager with this client's estimate.
      try {
        final tt =
            (j['ttproc_ms'] as num?)
                    ?.toDouble() ??
                0.0;

        final bw =
            (j['bandwidth_kBps'] as num?)
                    ?.toDouble() ??
                0.0;

        distributionManager.registerClient(
          clientId,
          ClientEstimate(
            ttprocMs: tt,
            bandwidthKbps: bw,
          ),
        );

        _logger.log(
          '🔧 Registered client $clientId '
          'in DistributionManager with '
          'tt=$tt ms, bw=$bw kB/s',
        );

        // If there are no units for the demo job,
        // register a small demo job so we can show
        // scheduling results.
        try {
          // The job is registered under the dataset's id (or 'demo_job' when
          // there is no dataset), so that is what must be checked. Checking
          // only 'demo_job' never matched, so every phone's warmup rebuilt the
          // job and reset the status of units that were already done or in
          // flight, and they were handed out again.
          if (!distributionManager.hasJob(
            _currentJobId(),
          )) {
            // Prefer a recently shared dataset
            // (zip / coco) to create units from.
            _logger.log(
              '🔍 Looking for a shared dataset '
              'to create demo_job units',
            );

            _SharedFile? datasetFile;

            try {
              datasetFile =
                  _sharedFiles.values
                      .toList()
                      .reversed
                      .firstWhere(
                (f) =>
                    f.mimeType ==
                        'application/zip' ||
                    f.name
                        .toLowerCase()
                        .contains('coco'),
                orElse: () => _SharedFile(
                  id: '',
                  file: File(''),
                  name: '',
                  size: 0,
                  mimeType: '',
                  dateAdded:
                      DateTime.now(),
                ),
              );

              if (datasetFile.id == '') {
                datasetFile = null;
              }
            } catch (_) {
              datasetFile = null;
            }

            List<Unit> jobUnits = [];

            if (datasetFile != null &&
                datasetFile.size > 0) {
              _logger.log(
                '🧾 Using shared dataset '
                '${datasetFile.name} '
                '(${_formatFileSize(datasetFile.size)}) '
                'for demo_job',
              );

              // If the shared dataset is a ZIP,
              // enumerate image entries and create
              // one unit per image.
              if (datasetFile.mimeType ==
                      'application/zip' ||
                  datasetFile.name
                      .toLowerCase()
                      .endsWith('.zip')) {
                try {
                  // Extracting here, before any worker asks, keeps the
                  // one-off extraction out of the measured download times.
                  final entries =
                      await _zipCache.entries(
                    datasetFile.id,
                    datasetFile.file,
                  );

                  final imageFiles =
                      entries.values.where(
                    (f) =>
                        // macOS adds "__MACOSX/._name.jpg" metadata files
                        // that are not images and would only fail.
                        !f.name.startsWith('__MACOSX/') &&
                        !path.basename(f.name).startsWith('._') &&
                        (f.name
                                .toLowerCase()
                                .endsWith('.jpg') ||
                            f.name
                                .toLowerCase()
                                .endsWith('.jpeg') ||
                            f.name
                                .toLowerCase()
                                .endsWith('.png') ||
                            f.name
                                .toLowerCase()
                                .endsWith('.bmp') ||
                            f.name
                                .toLowerCase()
                                .endsWith('.webp')),
                  ).toList();

                  if (imageFiles.isNotEmpty) {
                    int idx = 0;

                    for (final af
                        in imageFiles) {
                      final entryName =
                          af.name;

                      final entrySize =
                          af.size;

                      final fileUrl =
                          '$networkServerUrl'
                          '/files/${datasetFile.id}'
                          '?entry=${Uri.encodeComponent(entryName)}';

                      jobUnits.add(
                        Unit(
                          unitIndex: idx++,
                          start: 0,
                          end: entrySize > 0
                              ? entrySize - 1
                              : 0,
                          fileUrl: fileUrl,
                        ),
                      );
                    }
                  } else {
                    _logger.log(
                      '⚠️ No image entries found '
                      'inside ZIP; falling back to '
                      'chunked units of the full file',
                    );

                    const int parts = 10;

                    final int chunk =
                        (datasetFile.size /
                                parts)
                            .ceil();

                    for (
                      int i = 0;
                      i < parts;
                      i++
                    ) {
                      final start =
                          i * chunk;

                      final end =
                          (i == parts - 1)
                              ? datasetFile.size -
                                  1
                              : ((i + 1) *
                                      chunk) -
                                  1;

                      final fileUrl =
                          '$networkServerUrl'
                          '/files/${datasetFile.id}';

                      jobUnits.add(
                        Unit(
                          unitIndex: i,
                          start: start,
                          end: end,
                          fileUrl: fileUrl,
                        ),
                      );
                    }
                  }
                } catch (e) {
                  _logger.log(
                    '⚠️ Error reading ZIP to '
                    'enumerate entries: $e - '
                    'falling back to chunked units',
                  );

                  const int parts = 10;

                  final int chunk =
                      (datasetFile.size /
                              parts)
                          .ceil();

                  for (
                    int i = 0;
                    i < parts;
                    i++
                  ) {
                    final start =
                        i * chunk;

                    final end =
                        (i == parts - 1)
                            ? datasetFile.size -
                                1
                            : ((i + 1) *
                                    chunk) -
                                1;

                    final fileUrl =
                        '$networkServerUrl'
                        '/files/${datasetFile.id}';

                    jobUnits.add(
                      Unit(
                        unitIndex: i,
                        start: start,
                        end: end,
                        fileUrl: fileUrl,
                      ),
                    );
                  }
                }
              } else {
                final fileUrl =
                    '$networkServerUrl'
                    '/files/${datasetFile.id}';

                const int parts = 10;

                final int chunk =
                    (datasetFile.size /
                            parts)
                        .ceil();

                for (
                  int i = 0;
                  i < parts;
                  i++
                ) {
                  final start =
                      i * chunk;

                  final end =
                      (i == parts - 1)
                          ? datasetFile.size -
                              1
                          : ((i + 1) *
                                  chunk) -
                              1;

                  jobUnits.add(
                    Unit(
                      unitIndex: i,
                      start: start,
                      end: end,
                      fileUrl: fileUrl,
                    ),
                  );
                }
              }
            } else {
              // Fallback to a dummy demo file path.
              _logger.log(
                '⚠️ No shared dataset found, '
                'falling back to dummy demo file '
                'for demo_job',
              );

              jobUnits =
                  List<Unit>.generate(
                10,
                (i) => Unit(
                  unitIndex: i,
                  start: i * 1000,
                  end:
                      (i + 1) * 1000 - 1,
                  fileUrl:
                      '${networkServerUrl}/files/demo',
                ),
              );
            }

            final jobId =
                datasetFile != null &&
                        datasetFile.id.isNotEmpty
                    ? datasetFile.id
                    : 'demo_job';

            distributionManager.registerJob(
              jobId,
              jobUnits,
            );

            _logger.log(
              '🧪 Registered job $jobId with '
              '${jobUnits.length} units for '
              'scheduling demo',
            );

            onWorkAvailable?.call(jobId);
          }
        } catch (e) {
          _logger.log(
            '⚠️ Error checking/creating demo_job: $e',
          );
        }

        // Produce a scheduling suggestion using
        // current client estimates and log assignments.
        try {
          final clients =
              distributionManager
                  .registeredClientIds;

          final suggestionSummary =
              <String, dynamic>{
            'time':
                DateTime.now()
                    .toIso8601String(),
            'type': 'suggestion',
            'assignments': <String, dynamic>{},
          };

          for (final cid in clients) {
            final jobIdForSuggestion =
                _sharedFiles.values.isNotEmpty
                    ? _sharedFiles.values
                        .toList()
                        .reversed
                        .first
                        .id
                    : 'demo_job';

            final assigned =
                distributionManager
                    .suggestNext(
              jobIdForSuggestion,
              cid,
              maxUnits: 2,
            );

            if (assigned.isNotEmpty) {
              _logger.log(
                '📈 Scheduling suggestion '
                'for $cid: '
                '${assigned.map((u) => u.unitIndex).toList()}',
              );

              (suggestionSummary[
                      'assignments']
                  as Map)[cid] = assigned
                  .map((u) => u.unitIndex)
                  .toList();
            } else {
              _logger.log(
                '📈 Scheduling suggestion '
                'for $cid: none',
              );

              (suggestionSummary[
                      'assignments']
                  as Map)[cid] = [];
            }
          }

          // Store recent suggestion.
          _schedulerLogs.insert(
            0,
            suggestionSummary,
          );

          if (_schedulerLogs.length > 50) {
            _schedulerLogs.removeLast();
          }
        } catch (e) {
          _logger.log(
            '⚠️ Error generating scheduling '
            'suggestions: $e',
          );
        }
      } catch (e) {
        _logger.log(
          '⚠️ Error seeding DistributionManager: $e',
        );
      }

      return shelf.Response.ok(
        jsonEncode({
          'status': 'ok',
        }),
        headers: {
          'Content-Type':
              'application/json',
        },
      );
    } catch (e) {
      _logger.log(
        '❌ Error processing warmup report: $e',
      );

      return shelf.Response.internalServerError(
        body: 'error',
      );
    }
  }

  /// Return current warmup reports as JSON.
  Future<shelf.Response> _handleWarmupStatus(
    shelf.Request request,
  ) async {
    try {
      return shelf.Response.ok(
        jsonEncode(_warmupReports),
        headers: {
          'Content-Type':
              'application/json',
        },
      );
    } catch (e) {
      _logger.log(
        '❌ Error serializing warmup reports: $e',
      );

      return shelf.Response.internalServerError(
        body: 'error',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // EXPERIMENT RESET
  // ---------------------------------------------------------------------------

  /// Reset all experiment-specific state.
  ///
  /// This is intentionally separate from server/client configuration.
  ///
  /// Preserved:
  /// - HTTP server
  /// - shared files
  /// - connected clients
  /// - client warmup/performance estimates
  /// - job configuration
  /// - selected scheduling algorithm
  /// - default max-units configuration
  ///
  /// Reset:
  /// - DistributionManager assignment state
  /// - scheduler logs
  /// - result reports
  /// - experiment metrics
  Future<shelf.Response> _handleResetExperiment(
    shelf.Request request,
  ) async {
    try {
      _logger.log(
        '🔄 Resetting current experiment...',
      );

      // Reset scheduler/unit assignment state.
      distributionManager.resetExperiment();

      // Clear experiment-specific server state.
      _schedulerLogs.clear();
      _resultReportsByJob.clear();
      MetricsStore.instance.clear();

      _logger.log(
        '✅ Experiment state reset successfully',
      );

      return shelf.Response.ok(
        jsonEncode({
          'status': 'ok',
          'message':
              'Experiment reset successfully',
        }),
        headers: {
          'Content-Type':
              'application/json',
        },
      );
    } catch (e) {
      _logger.log(
        '❌ Error resetting experiment: $e',
      );

      return shelf.Response.internalServerError(
        body: jsonEncode({
          'status': 'error',
          'message':
              'Failed to reset experiment',
        }),
        headers: {
          'Content-Type':
              'application/json',
        },
      );
    }
  }

  // ---------------------------------------------------------------------------
  // JOB STATUS
  // ---------------------------------------------------------------------------

  /// Return job status: progress and per-client
  /// assigned units.
  Future<shelf.Response> _handleJobStatus(
    shelf.Request request,
  ) async {
    try {
      // Collect jobs known to distribution manager.
      final jobs =
          <String, dynamic>{};

      try {
        // DistributionManager keeps jobs internally;
        // access via jobProgress and registeredClientIds.
        final clients =
            distributionManager
                .registeredClientIds;

        for (final cid in clients) {
          final q =
              distributionManager
                  .getClientQueue(cid);

          jobs[cid] = q
              .map(
                (u) => {
                  'unitIndex':
                      u.unitIndex,
                  'fileUrl':
                      u.fileUrl,
                },
              )
              .toList();
        }
      } catch (_) {}

      // Include job progress for demo_job fallback
      // plus any other job ids known via shared files.
      final progress =
          <String, dynamic>{};

      try {
        final candidateIds =
            <String>{'demo_job'};

        candidateIds.addAll(
          _sharedFiles.keys,
        );

        for (final jid in candidateIds) {
          final p =
              distributionManager.jobProgress(
            jid,
          );

          if (p['total'] != 0) {
            progress[jid] = p;
          }
        }
      } catch (_) {}

      final Map<String, dynamic> out = {
        'per_client_queues': jobs,
        'progress': progress,
      };

      final Map<String, dynamic> recent = {};

      try {
        for (final e
            in _resultReportsByJob.entries) {
          recent[e.key] = e.value;
        }
      } catch (_) {}

      out['recent_results'] = recent;

      return shelf.Response.ok(
        jsonEncode(out),
        headers: {
          'Content-Type':
              'application/json',
        },
      );
    } catch (e) {
      _logger.log(
        '❌ Error generating job status: $e',
      );

      return shelf.Response.internalServerError(
        body: 'error',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // SCHEDULER LOGS
  // ---------------------------------------------------------------------------

  Future<shelf.Response> _handleSchedulerLogs(
    shelf.Request request,
  ) async {
    try {
      return shelf.Response.ok(
        jsonEncode(_schedulerLogs),
        headers: {
          'Content-Type':
              'application/json',
        },
      );
    } catch (e) {
      _logger.log(
        '❌ Error serializing scheduler logs: $e',
      );

      return shelf.Response.internalServerError(
        body: 'error',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // METRICS DOWNLOAD
  // ---------------------------------------------------------------------------

  /// Assemble the data for [buildExperimentReport] from the live state.
  String _buildReport({
    required String fileName,
    required DateTime generatedAt,
  }) {
    final store = MetricsStore.instance;
    final jobId = _currentJobId();
    final dataset = _sharedFiles[jobId];

    final models = <String>{
      for (final r in _warmupReports.values)
        if (r['model'] is String && (r['model'] as String).isNotEmpty) r['model'] as String,
    }.toList()
      ..sort();

    DeviceMetrics metricsFor(String ip, String name) =>
        store.device(ip) ?? DeviceMetrics(ip, name);

    final devices = <ReportDevice>[];

    for (final cid in distributionManager.registeredClientIds) {
      final name = deviceNameFromClientId(cid);
      final ip = deviceKeyFromClientId(cid);
      final dm = metricsFor(ip, name);

      devices.add(ReportDevice(
        name: name,
        ip: ip,
        isMaster: false,
        imagesProcessed: dm.units.length,
        summary: store.summarize(dm),
        traffic: store.trafficOf(dm),
      ));
    }

    final host = store.local;

    devices.add(ReportDevice(
      name: host.name,
      ip: host.key,
      isMaster: true,
      imagesProcessed: 0,
      summary: store.summarize(host),
      traffic: store.trafficOf(host),
    ));

    final start = store.experimentStartMs;

    return buildExperimentReport(
      fileName: fileName,
      generatedAt: generatedAt,
      experimentStart: start == null ? null : DateTime.fromMillisecondsSinceEpoch(start),
      models: models,
      datasetName: dataset?.name,
      datasetBytes: dataset?.size,
      datasetUnits: distributionManager.jobProgress(jobId)['total'] ?? 0,
      schedulerName: '${distributionManager.schedulerName} (${distributionManager.schedulerId})',
      scheduleCalls: distributionManager.scheduleCalls,
      avgScheduleMs: distributionManager.avgScheduleMs,
      devices: devices,
    );
  }

  /// Generate a plain-text metrics report for the current experiment.
  ///
  /// The report contains only information accumulated since the most recent
  /// experiment reset/start:
  /// - experiment timestamp
  /// - scheduling activity
  /// - job progress
  /// - per-result client metrics
  /// - aggregate client metrics
  ///
  /// Warmup information and persistent configuration are intentionally excluded.
  Future<shelf.Response> _handleDownloadMetrics(
    shelf.Request request,
  ) async {
    try {
      _logger.log(
        '📊 Metrics download requested',
      );

      final buffer =
          StringBuffer();

      final generatedAt =
          DateTime.now();

      // Header sections: file name and time, model, dataset, algorithm,
      // clients, per-client images, compute/network metrics, packets/overhead.
      buffer.write(_buildReport(
        fileName: MetricsStore.safeFileName(
          request.url.queryParameters['name'],
        ),
        generatedAt: generatedAt,
      ));

      buffer.writeln();
      buffer.writeln('=======================================');
      buffer.writeln('DETAILED LOGS');
      buffer.writeln('=======================================');
      buffer.writeln();

      // -----------------------------------------------------------------------
      // SCHEDULING SUMMARY
      // -----------------------------------------------------------------------

      buffer.writeln(
        'SCHEDULING ACTIVITY',
      );
      buffer.writeln(
        '-------------------',
      );

      if (_schedulerLogs.isEmpty) {
        buffer.writeln(
          'No scheduling activity recorded.',
        );
      } else {
        buffer.writeln(
          'Total log entries: ${_schedulerLogs.length}',
        );

        buffer.writeln();

        for (int i = 0;
            i < _schedulerLogs.length;
            i++) {
          final entry =
              _schedulerLogs[i];

          buffer.writeln(
            'Entry ${i + 1}:',
          );

          entry.forEach(
            (key, value) {
              buffer.writeln(
                '  $key: $value',
              );
            },
          );

          buffer.writeln();
        }
      }

      // -----------------------------------------------------------------------
      // RESULT SUMMARY
      // -----------------------------------------------------------------------

      buffer.writeln(
        'RESULT SUMMARY',
      );
      buffer.writeln(
        '--------------',
      );

      int totalResults = 0;
      double totalProcessingTime = 0.0;
      double totalBandwidth = 0.0;

      final Map<String, int>
          resultsPerClient = {};

      final Map<String, List<double>>
          processingTimesByClient = {};

      final Map<String, List<double>>
          bandwidthByClient = {};

      for (final jobEntry
          in _resultReportsByJob.entries) {
        final jobId = jobEntry.key;
        final results = jobEntry.value;

        buffer.writeln(
          'Job: $jobId',
        );
        buffer.writeln(
          '  Results: ${results.length}',
        );

        for (final result
            in results) {
          totalResults++;

          final clientId =
              '${result['clientId'] ?? result['client_id'] ?? 'unknown'}';

          final ttprocValue =
              result['ttprocMs'] ??
                  result['ttproc_ms'];

          final bandwidthValue =
              result['bandwidthKbps'] ??
                  result['bandwidth_kbps'];

          final ttproc =
              ttprocValue is num
                  ? ttprocValue
                      .toDouble()
                  : double.tryParse(
                        '$ttprocValue',
                      ) ??
                      0.0;

          final bandwidth =
              bandwidthValue is num
                  ? bandwidthValue
                      .toDouble()
                  : double.tryParse(
                        '$bandwidthValue',
                      ) ??
                      0.0;

          totalProcessingTime +=
              ttproc;

          totalBandwidth +=
              bandwidth;

          resultsPerClient[
                  clientId] =
              (resultsPerClient[
                          clientId] ??
                      0) +
                  1;

          processingTimesByClient
              .putIfAbsent(
            clientId,
            () => [],
          )
              .add(ttproc);

          bandwidthByClient
              .putIfAbsent(
            clientId,
            () => [],
          )
              .add(bandwidth);

          buffer.writeln(
            '  Unit: '
            '${result['unitIndex'] ?? result['unit_index'] ?? 'unknown'}',
          );

          buffer.writeln(
            '    Client: $clientId',
          );

          buffer.writeln(
            '    Processing time (ms): '
            '${ttproc.toStringAsFixed(3)}',
          );

          buffer.writeln(
            '    Bandwidth (kB/s): '
            '${bandwidth.toStringAsFixed(3)}',
          );

          if (result['received_at'] != null) {
            buffer.writeln(
              '    Received at: '
              '${result['received_at']}',
            );
          }
        }

        buffer.writeln();
      }

      buffer.writeln(
        'Total results: $totalResults',
      );

      if (totalResults > 0) {
        buffer.writeln(
          'Average processing time (ms): '
          '${(totalProcessingTime / totalResults).toStringAsFixed(3)}',
        );

        buffer.writeln(
          'Average bandwidth (kB/s): '
          '${(totalBandwidth / totalResults).toStringAsFixed(3)}',
        );
      } else {
        buffer.writeln(
          'Average processing time (ms): 0.000',
        );

        buffer.writeln(
          'Average bandwidth (kB/s): 0.000',
        );
      }

      buffer.writeln();

      // -----------------------------------------------------------------------
      // PER-CLIENT SUMMARY
      // -----------------------------------------------------------------------

      buffer.writeln(
        'PER-CLIENT SUMMARY',
      );
      buffer.writeln(
        '------------------',
      );

      if (resultsPerClient.isEmpty) {
        buffer.writeln(
          'No client result data recorded.',
        );
      } else {
        for (final clientId
            in resultsPerClient.keys) {
          final resultCount =
              resultsPerClient[
                  clientId]!;

          final processingValues =
              processingTimesByClient[
                      clientId] ??
                  [];

          final bandwidthValues =
              bandwidthByClient[
                      clientId] ??
                  [];

          final avgProcessing =
              processingValues.isEmpty
                  ? 0.0
                  : processingValues
                          .reduce(
                            (a, b) => a + b,
                          ) /
                      processingValues.length;

          final avgBandwidth =
              bandwidthValues.isEmpty
                  ? 0.0
                  : bandwidthValues
                          .reduce(
                            (a, b) => a + b,
                          ) /
                      bandwidthValues.length;

          buffer.writeln(
            'Client: $clientId',
          );

          buffer.writeln(
            '  Results completed: '
            '$resultCount',
          );

          buffer.writeln(
            '  Average processing time (ms): '
            '${avgProcessing.toStringAsFixed(3)}',
          );

          buffer.writeln(
            '  Average bandwidth (kB/s): '
            '${avgBandwidth.toStringAsFixed(3)}',
          );

          buffer.writeln();
        }
      }

      // -----------------------------------------------------------------------
      // JOB PROGRESS
      // -----------------------------------------------------------------------

      buffer.writeln(
        'JOB PROGRESS',
      );
      buffer.writeln(
        '------------',
      );

      final candidateJobIds =
          <String>{'demo_job'};

      candidateJobIds.addAll(
        _sharedFiles.keys,
      );

      bool foundJob = false;

      for (final jobId
          in candidateJobIds) {
        final progress =
            distributionManager
                .jobProgress(jobId);

        if (progress['total'] != 0) {
          foundJob = true;

          buffer.writeln(
            'Job: $jobId',
          );

          buffer.writeln(
            '  Total: '
            '${progress['total']}',
          );

          buffer.writeln(
            '  Completed: '
            '${progress['completed']}',
          );

          buffer.writeln(
            '  Assigned: '
            '${progress['assigned']}',
          );

          buffer.writeln(
            '  Available: '
            '${progress['available']}',
          );

          buffer.writeln();
        }
      }

      if (!foundJob) {
        buffer.writeln(
          'No job progress data available.',
        );
      }

      final metricsText =
          buffer.toString();

      return shelf.Response.ok(
        metricsText,
        headers: {
          'Content-Type':
              'text/plain; charset=utf-8',
          'Content-Disposition':
              'attachment; filename="${MetricsStore.safeFileName(request.url.queryParameters['name'])}.txt"',
          'Cache-Control':
              'no-cache, no-store, must-revalidate',
          'Pragma': 'no-cache',
          'Expires': '0',
        },
      );
    } catch (e) {
      _logger.log(
        '❌ Error generating experiment metrics: $e',
      );

      return shelf.Response.internalServerError(
        body: 'error',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // ASSIGNMENTS
  // ---------------------------------------------------------------------------

  /// Return per-client assignment for a job
  /// (non-destructive).
  Future<shelf.Response>
      _handleGetAssignmentForClient(
    shelf.Request request,
    String jobId,
    String clientId,
  ) async {
    try {
      final queue =
          distributionManager
              .getClientQueue(clientId);

      final assignment =
          PerClientAssignment(
        jobId: jobId,
        clientId: clientId,
        units: queue,
      );

      return shelf.Response.ok(
        jsonEncode(
          assignment.toJson(),
        ),
        headers: {
          'Content-Type':
              'application/json',
        },
      );
    } catch (e) {
      _logger.log(
        '❌ Error fetching assignment for '
        '$clientId on $jobId: $e',
      );

      return shelf.Response.internalServerError(
        body: 'error',
      );
    }
  }

  /// Request next assignment for a client.
  Future<shelf.Response>
      _handleGetNextAssignment(
    shelf.Request request,
    String jobId,
  ) async {
    try {
      final clientId =
          request.url.queryParameters['for'] ??
              'unknown';

      if (clientId == 'unknown') {
        return shelf.Response(
          400,
          body: 'missing client id',
        );
      }

      // Determine maxUnits:
      // explicit query parameter,
      // then job default,
      // then 2.
      int maxUnits = 2;

      try {
        final q =
            request.url.queryParameters['max'];

        if (q != null) {
          maxUnits =
              int.tryParse(q) ??
                  maxUnits;
        } else if (_jobDefaultUnits
            .containsKey(jobId)) {
          maxUnits =
              _jobDefaultUnits[jobId]!;
        }
      } catch (_) {}

      // Asking for work proves the phone is alive, even before it has
      // finished a unit or sent any metrics.
      distributionManager.touchClient(clientId);
      MetricsStore.instance.recordPoll(deviceKeyFromClientId(clientId));

      final units =
          distributionManager.assignNext(
        jobId,
        clientId,
        maxUnits: maxUnits,
      );

      // Read straight after the call: it is the decision that produced
      // these units, not a later preview.
      final trace =
          distributionManager.lastDecisionTrace;

      final assignment =
          PerClientAssignment(
        jobId: jobId,
        clientId: clientId,
        units: units,
      );

      _logger.log(
        '📦 Assigned ${units.length} units '
        'to $clientId for job $jobId',
      );

      if (units.isEmpty) {
        // If job does not exist, log clearly.
        if (!distributionManager
            .hasJob(jobId)) {
          _logger.log(
            '⚠️ Request for next assignment: '
            'job $jobId not found',
          );

          return shelf.Response.notFound(
            'job_not_found',
          );
        }

        // No units available right now.
        try {
          final prog =
              distributionManager
                  .jobProgress(jobId);

          final body = jsonEncode({
            'job_id': jobId,
            'client_id': clientId,
            'units': [],
            'progress': prog,
          });

          return shelf.Response.ok(
            body,
            headers: {
              'Content-Type':
                  'application/json',
            },
          );
        } catch (_) {}
      }

      // Record assignment in scheduler logs.
      try {
        _schedulerLogs.insert(
          0,
          {
            'time':
                DateTime.now()
                    .toIso8601String(),
            'type': 'assignment',
            'job': jobId,
            'client': clientId,
            'units': units
                .map(
                  (u) => u.unitIndex,
                )
                .toList(),
            'trace': trace,
          },
        );

        if (_schedulerLogs.length > 50) {
          _schedulerLogs.removeLast();
        }
      } catch (_) {}

      // Keep a longer, exportable history of who got what and how each phone scored.
      try {
        if (units.isNotEmpty) {
          final scored = <String, double>{};
          final clientsTrace = trace?['clients'];
          if (clientsTrace is Map) {
            clientsTrace.forEach((id, v) {
              if (v is Map && v['health'] is num) {
                scored[deviceKeyFromClientId('$id')] = (v['health'] as num).toDouble();
              }
            });
          }
          MetricsStore.instance.recordDecision(DecisionRecord(
            t: DateTime.now().millisecondsSinceEpoch,
            deviceKey: deviceKeyFromClientId(clientId),
            deviceName: deviceNameFromClientId(clientId),
            units: units.map((u) => u.unitIndex).toList(),
            scheduler: distributionManager.schedulerId,
            healthByDevice: scored,
          ));
        }
      } catch (_) {}

      return shelf.Response.ok(
        jsonEncode(
          assignment.toJson(),
        ),
        headers: {
          'Content-Type':
              'application/json',
        },
      );
    } catch (e) {
      _logger.log(
        '❌ Error assigning next units for '
        '$jobId: $e',
      );

      return shelf.Response.internalServerError(
        body: 'error',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // JOB OPTIONS
  // ---------------------------------------------------------------------------

  /// Admin: set job options such as default
  /// max units per assignment.
  Future<shelf.Response>
      _handleSetJobOptions(
    shelf.Request request,
  ) async {
    try {
      final body =
          await request.readAsString();

      final j =
          jsonDecode(body)
              as Map<String, dynamic>;

      final jobId =
          j['job_id'] as String?;

      if (jobId == null) {
        return shelf.Response(
          400,
          body: 'missing job_id',
        );
      }

      final defaultMax =
          (j['default_max_units'] is int)
              ? j['default_max_units']
                  as int
              : int.tryParse(
                    '${j['default_max_units']}',
                  ) ??
                  0;

      if (defaultMax > 0) {
        _jobDefaultUnits[jobId] =
            defaultMax;

        _logger.log(
          '⚙️ Set default_max_units for '
          '$jobId -> $defaultMax',
        );

        return shelf.Response.ok(
          jsonEncode({
            'status': 'ok',
          }),
          headers: {
            'Content-Type':
                'application/json',
          },
        );
      }

      return shelf.Response(
        400,
        body: 'invalid default_max_units',
      );
    } catch (e) {
      _logger.log(
        '❌ Error setting job options: $e',
      );

      return shelf.Response.internalServerError(
        body: 'error',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // RESULT REPORTS
  // ---------------------------------------------------------------------------

  /// Receive result reports from clients for job units.
  Future<shelf.Response>
      _handlePostResultReport(
    shelf.Request request,
    String jobId,
  ) async {
    try {
      final body =
          await request.readAsString();

      final j =
          jsonDecode(body)
              as Map<String, dynamic>;

      final rr =
          ResultReport.fromJson(j);

      if (rr.failed) {
        return _handleFailedUnit(jobId, rr);
      }

      // Mark unit complete, then fold the report (estimate, latency and the
      // health the phone attached) into that client's live state.
      distributionManager.markUnitComplete(
        jobId,
        rr.unitIndex,
      );

      distributionManager.recordResult(rr);

      _logger.log(
        '✅ Result received for job '
        '${rr.jobId} unit ${rr.unitIndex} '
        'from ${rr.clientId} '
        '(infer=${rr.ttprocMs}ms '
        'download=${rr.downloadMs}ms '
        'bw=${rr.bandwidthKbps.toStringAsFixed(1)}kB/s)',
      );

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

      // Produce a quick scheduler summary
      // after receiving result.
      try {
        final summary =
            distributionManager
                .jobProgress(jobId);

        _logger.log(
          '📊 Job $jobId progress: '
          'total=${summary['total']} '
          'completed=${summary['completed']} '
          'available=${summary['available']}',
        );

        // Append to scheduler logs.
        _schedulerLogs.insert(
          0,
          {
            'time':
                DateTime.now()
                    .toIso8601String(),
            'type': 'progress',
            'job': jobId,
            'progress': summary,
          },
        );

        if (_schedulerLogs.length > 50) {
          _schedulerLogs.removeLast();
        }

        // Store recent result for UI inspection.
        try {
          final list =
              _resultReportsByJob.putIfAbsent(
            jobId,
            () =>
                <Map<String, dynamic>>[],
          );

          // Attempt to lookup the unit's fileUrl
          // from internal job list for convenience.
          String? fileUrl;

          try {
            fileUrl =
                distributionManager
                    .getUnitFileUrl(
              jobId,
              rr.unitIndex,
            );
          } catch (_) {}

          // Store with a received timestamp
          // for UI display and include original
          // file URL so host can fetch image.
          final entry =
              <String, dynamic>{
            'received_at':
                DateTime.now()
                    .toIso8601String(),
            'file_url': fileUrl,
            ...rr.toJson(),
          };

          list.insert(
            0,
            entry,
          );

          if (list.length > 200) {
            list.removeLast();
          }
        } catch (_) {}
      } catch (_) {}

      return shelf.Response.ok(
        jsonEncode({
          'status': 'ok',
        }),
        headers: {
          'Content-Type':
              'application/json',
        },
      );
    } catch (e) {
      _logger.log(
        '❌ Error processing result report: $e',
      );

      return shelf.Response.internalServerError(
        body: 'error',
      );
    }
  }

  /// A worker could not process a unit. It goes back to the pool at once and
  /// is left out of the unit records and recent results, so it never counts
  /// as a completed image with no detections.
  shelf.Response _handleFailedUnit(
    String jobId,
    ResultReport rr,
  ) {
    final outcome =
        distributionManager.markUnitFailed(
      jobId,
      rr.unitIndex,
      rr.clientId,
    );

    final health = rr.health;

    if (health != null) {
      distributionManager.updateClientHealth(
        rr.clientId,
        health,
      );
    }

    final what = switch (outcome) {
      UnitFailureOutcome.requeued => 're-queued',
      UnitFailureOutcome.abandoned =>
        'given up after '
            '${distributionManager.maxUnitAttempts} failures',
      UnitFailureOutcome.ignored =>
        'already done or held by another phone',
    };

    _logger.log(
      '↩️ Unit ${rr.unitIndex} of job $jobId '
      'failed on ${rr.clientId}: ${rr.error} ($what)',
    );

    _schedulerLogs.insert(
      0,
      {
        'time':
            DateTime.now().toIso8601String(),
        'type': 'failure',
        'job': jobId,
        'unit': rr.unitIndex,
        'client': rr.clientId,
        'error': rr.error,
        'outcome': outcome.name,
      },
    );

    if (_schedulerLogs.length > 50) {
      _schedulerLogs.removeLast();
    }

    if (outcome == UnitFailureOutcome.requeued) {
      onWorkAvailable?.call(jobId);
    }

    return shelf.Response.ok(
      jsonEncode({
        'status': 'ok',
        'outcome': outcome.name,
      }),
      headers: {
        'Content-Type': 'application/json',
      },
    );
  }

  // ---------------------------------------------------------------------------
  // PER-PHONE METRICS + SCHEDULER SELECTION
  // ---------------------------------------------------------------------------

  /// Counts every HTTP body byte this phone serves/receives, per peer, so the
  /// host's own network load can be attributed to each worker.
  shelf.Middleware _trafficMiddleware() {
    return (shelf.Handler inner) {
      return (shelf.Request request) async {
        final channel = request.url.path.startsWith('files') ? TrafficChannel.httpData : TrafficChannel.httpControl;
        final info = request.context['shelf.io.connection_info'];
        final peer = info is HttpConnectionInfo ? info.remoteAddress.address : null;
        // One request in, one response out, whatever the number of body chunks.
        TrafficCounter.instance.countRxMsg(channel);
        TrafficCounter.instance.countTxMsg(channel);
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

  // ---------------------------------------------------------------------------
  // PUBLIC GETTERS
  // ---------------------------------------------------------------------------

  /// Expose warmup reports for UI polling.
  Map<String, Map<String, dynamic>>
      get warmupReports =>
          Map.from(_warmupReports);

  // ---------------------------------------------------------------------------
  // UTILITY METHODS
  // ---------------------------------------------------------------------------

  /// Get MIME type based on file extension.
  String _getMimeType(
    String extension,
  ) {
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

  /// Format file size for display.
  String _formatFileSize(
    int bytes,
  ) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes <
        1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(2)} KB';
    } else if (bytes <
        1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }

  // ---------------------------------------------------------------------------
  // CLEANUP
  // ---------------------------------------------------------------------------

  /// Clean up resources.
  void dispose() {
    stopServer();
  }
}

// -----------------------------------------------------------------------------
// SHARED FILE MODEL
// -----------------------------------------------------------------------------

/// Information about a shared file.
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

// -----------------------------------------------------------------------------
// FILE SHARE INFORMATION
// -----------------------------------------------------------------------------

/// File share information for sending via MQTT.
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

  factory FileShareInfo.fromJson(
    Map<String, dynamic> json,
  ) {
    return FileShareInfo(
      fileId: json['fileId'],
      fileName: json['fileName'],
      fileSize: json['fileSize'],
      mimeType: json['mimeType'],
      url: json['url'],
    );
  }
}