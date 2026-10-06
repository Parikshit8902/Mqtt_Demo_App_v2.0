import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'results_gallery_screen.dart';
import '../services/mqtt_service.dart';
import '../widgets/message_log.dart';
import '../widgets/file_share_widget.dart';
import '../services/topic_manager.dart';
import '../services/distribution_singleton.dart';
import '../services/schedulers/scheduler_type.dart';
import '../widgets/scheduling_algorithm_selector.dart';

enum DistributionStep {
  idle,
  sharingModel,
  modelShared,
  sharingData,
  dataShared
}
class HostSessionScreen extends StatefulWidget {
  final MqttService mqttService;
  final VoidCallback onBackToHome;
  final bool showMessageLog;
  const HostSessionScreen({
    super.key,
    required this.mqttService,
    required this.onBackToHome,
    this.showMessageLog = true,
  });
  @override
  State<HostSessionScreen> createState() =>
      _HostSessionScreenState();
}
class _HostSessionScreenState
    extends State<HostSessionScreen> {
  final ScrollController _scrollController =
      ScrollController();
  final TextEditingController _messageController =
      TextEditingController();
  bool _isStarting = false;
  bool _isProcessingDistribution = false;
  String _selectedTopic = '';
  File? _selectedModelFile;
  File? _selectedDatasetFile;
  int _unitsPerAssignment = 2;
  // warmup UI state
  bool _modelWarmupReceived = false;
  double? _modelWarmupTtprocMs;
  double? _modelWarmupBwKbps;
  // Job status state
  Map<String, dynamic> _jobProgress = {};
  Map<String, List<dynamic>> _perClientQueues = {};
  Map<String, List<dynamic>> _recentResults = {};
  // recent results are shown in a dedicated gallery screen
  // (kept server-side); no in-screen recent list required here
  // viewer state removed — ResultsGalleryScreen handles viewing
  Timer? _jobStatusTimer;
  // Distribution state
  DistributionStep _distributionStep =
      DistributionStep.idle;
  final List<String> _ackedModelIps = [];
  final List<String> _ackedDataIps = [];
  bool _showModelIps = false;
  bool _showDataIps = false;
  @override
  void initState() {
    super.initState();
    widget.mqttService
        .addListener(_onMqttServiceChanged);
    _messageController.text =
        'Hello from host!';
    _selectedTopic =
        widget.mqttService.defaultTopic;
    // ensure broker mode is set when opening this screen
    if (!widget.mqttService.isBrokerRunning) {
      _startHosting();
    } else {
      widget.mqttService.setMode(
        AppMode.broker,
      );
    }
  }
  String _shortenId(
    String id, {
    int head = 8,
    int tail = 6,
  }) {
    if (id.length <= head + tail + 3) {
      return id;
    }
    return '${id.substring(0, head)}...'
        '${id.substring(id.length - tail)}';
  }
  @override
  void dispose() {
    widget.mqttService
        .removeListener(_onMqttServiceChanged);
    _scrollController.dispose();
    _messageController.dispose();
    super.dispose();
  }
  // Poll job status periodically while distribution is active
  void _startJobStatusPolling() {
    _jobStatusTimer?.cancel();
    _jobStatusTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) async {
        try {
          final base =
              widget.mqttService.serverUrl;
          final url =
              Uri.parse('$base/admin/job_status');
          final resp =
              await http.get(url);
          if (resp.statusCode == 200) {
            final j =
                jsonDecode(resp.body)
                    as Map<String, dynamic>;
            setState(() {
              _perClientQueues =
                  (j['per_client_queues']
                              as Map<String, dynamic>)
                      .map(
                        (k, v) => MapEntry(
                          k,
                          (v as List)
                              .cast<
                                  Map<String,
                                      dynamic>>(),
                        ),
                      );
              _jobProgress =
                  (j['progress']
                          as Map<String, dynamic>?) ??
                      {};
              _recentResults =
                  (j['recent_results']
                              as Map<String,
                                  dynamic>?)
                          ?.map(
                            (k, v) => MapEntry(
                              k,
                              (v as List).cast<
                                  Map<String,
                                      dynamic>>(),
                            ),
                          ) ??
                      {};
              // recent results intentionally not stored
              // inline; gallery screen will fetch them
              // when needed
            });
          }
        } catch (_) {}
      },
    );
  }
  void _stopJobStatusPolling() {
    _jobStatusTimer?.cancel();
    _jobStatusTimer = null;
  }
  // Change the scheduling algorithm used by the host.
  void _changeSchedulingAlgorithm(
    SchedulerType type,
  ) {
    distributionManager
        .setSchedulerType(type);
    setState(() {});
    ScaffoldMessenger.of(context)
        .showSnackBar(
      SnackBar(
        content: Text(
          'Scheduling algorithm changed to '
          '${type.displayName}',
        ),
        duration:
            const Duration(seconds: 2),
      ),
    );
  }
  // Poll the host file server for warmup reports
  // and update UI
  Future<void> _pollWarmupReports() async {
    final base =
        widget.mqttService.serverUrl;
    final url =
        Uri.parse('$base/admin/warmup');
    final logsUrl =
        Uri.parse('$base/admin/scheduler_logs');
    // Poll for up to 15 seconds waiting for
    // any warmup report
    for (
      int attempt = 0;
      attempt < 15;
      attempt++
    ) {
      try {
        final resp =
            await http.get(url);
        if (resp.statusCode == 200) {
          final Map<String, dynamic> j =
              jsonDecode(resp.body)
                  as Map<String, dynamic>;
          if (j.isNotEmpty) {
            final first =
                j.values.first
                    as Map<String, dynamic>;
            setState(() {
              _modelWarmupReceived = true;
              _modelWarmupTtprocMs =
                  (first['ttproc_ms'] as num?)
                      ?.toDouble() ??
                  (first['ttproc_ms'] as int?)
                      ?.toDouble();
              _modelWarmupBwKbps =
                  (first['bandwidth_kBps'] as num?)
                      ?.toDouble();
            });
            widget.mqttService
                .topicManager
                .addMessage(
                  topic: 'admin/warmup_log',
                  content:
                      'Warmup from '
                      '${first['client_id']}: '
                      'ttproc=$_modelWarmupTtprocMs, '
                      'bw=$_modelWarmupBwKbps',
                  senderId: 'host',
                  senderName: 'Host',
                  type: MessageType.user,
                );
            // fetch scheduler logs too
            try {
              final lr =
                  await http.get(logsUrl);
              if (lr.statusCode == 200) {
                final list =
                    jsonDecode(lr.body)
                        as List<dynamic>;
                // store latest few logs into topic
                // manager for visibility
                for (
                  final e
                      in list
                          .cast<
                              Map<String,
                                  dynamic>>()
                          .take(10)
                ) {
                  widget.mqttService
                      .topicManager
                      .addMessage(
                        topic: 'admin/scheduler',
                        content: e.toString(),
                        senderId: 'host',
                        senderName: 'Host',
                        type: MessageType.user,
                      );
                }
              }
            } catch (_) {}
            break;
          }
        }
      } catch (e) {
        // continue polling
      }
      await Future.delayed(
        const Duration(seconds: 1),
      );
    }
  }
  void _onMqttServiceChanged() {
    // start polling job status when dataset is shared
    if (_distributionStep ==
        DistributionStep.dataShared) {
      _startJobStatusPolling();
    } else {
      _stopJobStatusPolling();
    }
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance
        .addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration:
              const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }
  Future<void> _startHosting() async {
    setState(() => _isStarting = true);
    widget.mqttService
        .setMode(AppMode.broker);
    final ok =
        await widget.mqttService.startBroker();
    if (!mounted) return;
    setState(
      () => _isStarting = false,
    );
    ScaffoldMessenger.of(context)
        .showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Session started — waiting for participants'
              : 'Failed to start session',
        ),
      ),
    );
  }
  Future<void> _stopHosting() async {
    await widget.mqttService.stopBroker();
    widget.onBackToHome();
  }
  Future<void> _pickModel() async {
    final result =
        await FilePicker.platform.pickFiles(
      allowMultiple: false,
      dialogTitle: 'Select model file',
    );
    if (
      result == null ||
      result.files.isEmpty ||
      result.files.first.path == null
    ) {
      return;
    }
    setState(
      () => _selectedModelFile =
          File(result.files.first.path!),
    );
  }
  Future<void> _pickDataset() async {
    final result =
        await FilePicker.platform.pickFiles(
      allowMultiple: false,
      dialogTitle: 'Select dataset file',
    );
    if (
      result == null ||
      result.files.isEmpty ||
      result.files.first.path == null
    ) {
      return;
    }
    setState(
      () => _selectedDatasetFile =
          File(result.files.first.path!),
    );
  }
  Future<void> _submitDistribution() async {
    if (
      widget.mqttService
          .connectedClients
          .isEmpty
    ) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content:
                Text('No participants connected'),
          ),
        );
      }
      return;
    }
    if (
      _selectedModelFile == null ||
      _selectedDatasetFile == null
    ) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'Select model and dataset before starting',
            ),
          ),
        );
      }
      return;
    }
    setState(() {
      _isProcessingDistribution = true;
      _distributionStep =
          DistributionStep.sharingModel;
      _ackedModelIps.clear();
      _ackedDataIps.clear();
      _showModelIps = false;
      _showDataIps = false;
    });
    // 1) Share model (broadcast)
    final modelSent =
        await widget.mqttService.shareFileToTopic(
      _selectedModelFile!,
      'dist/mod',
    );
    if (!mounted) return;
    if (!modelSent) {
      setState(() {
        _isProcessingDistribution = false;
        _distributionStep =
            DistributionStep.idle;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content:
              Text('Failed to share model'),
        ),
      );
      return;
    }
    // keep showing "sharing" until ACKs are collected
    ScaffoldMessenger.of(context)
        .showSnackBar(
      const SnackBar(
        content:
            Text(
              'Model published — waiting for client ACKs',
            ),
      ),
    );
    // 2) Collect model ACKs on ack/mod
    // (30s or until all connected clients ack)
    final expected =
        widget.mqttService.connectedClientsCount;
    final Set<String> modelAckSet = {};
    final modelCompleter =
        Completer<Set<String>>();
    // subscribe and collect existing messages
    try {
      await widget.mqttService
          .subscribeToTopic('ack/mod');
      await Future.delayed(
        const Duration(milliseconds: 200),
      );
    } catch (_) {}
    try {
      final existing =
          widget.mqttService.topicManager
              .getMessagesForTopic(
                'ack/mod',
              );
      for (final m in existing) {
        if (m.content.isNotEmpty) {
          modelAckSet.add(
            m.content.trim(),
          );
        }
      }
    } catch (_) {}
    void modelAckListener(
      String topic,
      String message,
    ) {
      if (message.isNotEmpty) {
        modelAckSet.add(
          message.trim(),
        );
      }
      if (
        modelAckSet.length >= expected &&
        !modelCompleter.isCompleted
      ) {
        modelCompleter.complete(
          modelAckSet,
        );
      }
    }
    widget.mqttService.addMessageListener(
      'ack/mod',
      modelAckListener,
    );
    Timer(
      const Duration(seconds: 30),
      () {
        if (!modelCompleter.isCompleted) {
          modelCompleter.complete(
            modelAckSet,
          );
        }
      },
    );
    final modelResult =
        await modelCompleter.future;
    widget.mqttService
        .removeMessageListener(
          'ack/mod',
          modelAckListener,
        );
    if (!mounted) return;
    if (modelResult.isEmpty) {
      // no clients acknowledged the model
      // — return to idle
      setState(() {
        _isProcessingDistribution = false;
        _distributionStep =
            DistributionStep.idle;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content:
              Text(
                'No ACKs received for model — aborting',
              ),
        ),
      );
      return;
    }
    // clients acknowledged the model —
    // mark model as shared, then start data sharing
    setState(() {
      _ackedModelIps.addAll(
        modelResult,
      );
      _distributionStep =
          DistributionStep.modelShared;
    });
    // move to sharing data before sending
    // dataset notifications
    setState(
      () => _distributionStep =
          DistributionStep.sharingData,
    );
    // 3) For each acking client, send dataset
    // notification targeted to that IP
    int success = 0;
    final List<String> failed = [];
    for (final ip in modelResult) {
      final ok =
          await widget.mqttService
              .shareFileToTopic(
        _selectedDatasetFile!,
        'dist/data',
        targetIp: ip,
      );
      if (ok) {
        success++;
      } else {
        failed.add(ip);
      }
      await Future.delayed(
        const Duration(milliseconds: 200),
      );
    }
    // After sharing the dataset, attempt to
    // register job options (units per assignment)
    try {
      final base =
          widget.mqttService.serverUrl;
      final filesUrl =
          Uri.parse('$base/files');
      final fr =
          await http.get(filesUrl);
      String jobId = 'demo_job';
      if (fr.statusCode == 200) {
        final list =
            jsonDecode(fr.body)
                as List<dynamic>;
        final name =
            _selectedDatasetFile
                ?.path
                .split('/')
                .last ??
            '';
        // try to find the most recent file
        // matching the dataset filename
        try {
          final found =
              list
                  .cast<
                      Map<String, dynamic>>()
                  .reversed
                  .firstWhere(
                    (f) => f['name'] == name,
                    orElse: () => {},
                  );
          if (
            found.isNotEmpty &&
            found['id'] != null
          ) {
            jobId =
                found['id'] as String;
          }
        } catch (_) {}
      }
      // post job options
      try {
        final optsUrl =
            Uri.parse(
              '$base/admin/job_options',
            );
        final body =
            jsonEncode({
          'job_id': jobId,
          'default_max_units':
              _unitsPerAssignment,
        });
        await http.post(
          optsUrl,
          body: body,
          headers: {
            'Content-Type':
                'application/json',
          },
        );
      } catch (_) {}
    } catch (_) {}
    // 4) Collect dataset ACKs on ack/data
    // for a short window (10s)
    final Set<String> dataAckSet = {};
    final dataCompleter =
        Completer<Set<String>>();
    try {
      await widget.mqttService
          .subscribeToTopic('ack/data');
      await Future.delayed(
        const Duration(milliseconds: 150),
      );
    } catch (_) {}
    try {
      final existingD =
          widget.mqttService.topicManager
              .getMessagesForTopic(
                'ack/data',
              );
      for (final m in existingD) {
        if (m.content.isNotEmpty) {
          dataAckSet.add(
            m.content.trim(),
          );
        }
      }
    } catch (_) {}
    void dataAckListener(
      String topic,
      String message,
    ) {
      if (message.isNotEmpty) {
        dataAckSet.add(
          message.trim(),
        );
      }
      if (
        dataAckSet.length >= modelResult.length &&
        !dataCompleter.isCompleted
      ) {
        dataCompleter.complete(
          dataAckSet,
        );
      }
    }
    widget.mqttService.addMessageListener(
      'ack/data',
      dataAckListener,
    );
    Timer(
      const Duration(seconds: 10),
      () {
        if (!dataCompleter.isCompleted) {
          dataCompleter.complete(
            dataAckSet,
          );
        }
      },
    );
    final dataResult =
        await dataCompleter.future;
    widget.mqttService
        .removeMessageListener(
          'ack/data',
          dataAckListener,
        );
    if (!mounted) return;
    setState(() {
      _ackedDataIps.addAll(
        dataResult,
      );
      _distributionStep =
          DistributionStep.dataShared;
      _isProcessingDistribution = false;
    });
    // start polling warmup reports briefly
    // to populate UI
    _pollWarmupReports();
    if (failed.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'Dataset notifications sent to '
            '$success/${modelResult.length} clients',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'Completed with failures: '
            'sent $success/${modelResult.length}. '
            'Failed: ${failed.join(', ')}',
          ),
        ),
      );
    }
  }
  Future<void> _publishMessage() async {
    final message =
        _messageController.text;
    await widget.mqttService.publishMessage(
      message: message,
      topic: _selectedTopic,
    );
  }
  void _onTopicChanged(
    String? newTopic,
  ) {
    if (newTopic == null) return;
    setState(
      () => _selectedTopic = newTopic,
    );
  }
  Widget _buildDistributionProgress() {
    // only visible while a distribution is active
    // or processing
    if (
      !widget.mqttService
          .connectedClients
          .isNotEmpty
    ) {
      return const SizedBox.shrink();
    }
    if (
      _distributionStep ==
          DistributionStep.idle &&
      !_isProcessingDistribution
    ) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 24,
        vertical: 8,
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Text(
            'Distribution Progress',
            style: Theme.of(context)
                .textTheme
                .titleMedium,
          ),
          const SizedBox(height: 8),
          // Model card
          Card(
            margin:
                const EdgeInsets.symmetric(
              vertical: 6,
            ),
            elevation: 0,
            shape:
                RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(8),
              side: BorderSide(
                color: Colors.grey.shade200,
              ),
            ),
            child: ListTile(
              dense: true,
              leading: Icon(
                _distributionStep.index >=
                        DistributionStep
                            .sharingModel
                            .index
                    ? Icons.check_circle
                    : Icons.schedule,
                color:
                    _distributionStep.index >=
                            DistributionStep
                                .sharingModel
                                .index
                        ? Colors.green
                        : Colors.grey,
              ),
              title: const Text(
                'Share Model',
                style: TextStyle(
                  fontWeight:
                      FontWeight.w600,
                ),
              ),
              subtitle: Text(
                _distributionStep.index >=
                        DistributionStep
                            .sharingModel
                            .index
                    ? 'Sent'
                    : 'Pending',
                style: TextStyle(
                  fontSize: 12,
                  color:
                      Colors.grey.shade600,
                ),
              ),
            ),
          ),
          // Model Shared card with show IPs button
          Card(
            margin:
                const EdgeInsets.symmetric(
              vertical: 6,
            ),
            elevation: 0,
            shape:
                RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(8),
              side: BorderSide(
                color: Colors.grey.shade200,
              ),
            ),
            child: Column(
              children: [
                ListTile(
                  dense: true,
                  leading: Icon(
                    _distributionStep.index >=
                            DistributionStep
                                .modelShared
                                .index
                        ? Icons.check_circle
                        : Icons.hourglass_top,
                    color:
                        _distributionStep.index >=
                                DistributionStep
                                    .modelShared
                                    .index
                            ? Colors.green
                            : Colors.grey,
                  ),
                  title: const Text(
                    'Model Shared',
                    style: TextStyle(
                      fontWeight:
                          FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    _distributionStep.index >=
                            DistributionStep
                                .modelShared
                                .index
                        ? 'Clients received'
                        : 'Waiting for ACKs',
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          Colors.grey.shade600,
                    ),
                  ),
                  trailing: TextButton(
                    onPressed:
                        _ackedModelIps.isEmpty
                            ? null
                            : () => setState(
                                  () =>
                                      _showModelIps =
                                          !_showModelIps,
                                ),
                    child: Text(
                      _showModelIps
                          ? 'Hide IPs'
                          : 'Show IPs',
                    ),
                  ),
                ),
                if (
                  _showModelIps &&
                  _ackedModelIps.isNotEmpty
                )
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment
                              .start,
                      children:
                          _ackedModelIps
                              .map(
                                (ip) => Padding(
                                  padding:
                                      const EdgeInsets
                                          .symmetric(
                                    vertical: 2,
                                  ),
                                  child: Text(
                                    ip,
                                    style: TextStyle(
                                      color: Colors
                                          .grey
                                          .shade800,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                    ),
                  ),
              ],
            ),
          ),
          // Share Dataset card
          Card(
            margin:
                const EdgeInsets.symmetric(
              vertical: 6,
            ),
            elevation: 0,
            shape:
                RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(8),
              side: BorderSide(
                color: Colors.grey.shade200,
              ),
            ),
            child: ListTile(
              dense: true,
              leading: Icon(
                _distributionStep.index >=
                        DistributionStep
                            .sharingData
                            .index
                    ? Icons.check_circle
                    : Icons.upload_file,
                color:
                    _distributionStep.index >=
                            DistributionStep
                                .sharingData
                                .index
                        ? Colors.green
                        : Colors.grey,
              ),
              title: const Text(
                'Share Dataset',
                style: TextStyle(
                  fontWeight:
                      FontWeight.w600,
                ),
              ),
              subtitle: Text(
                _distributionStep.index >=
                        DistributionStep
                            .sharingData
                            .index
                    ? 'Notified'
                    : 'Pending',
                style: TextStyle(
                  fontSize: 12,
                  color:
                      Colors.grey.shade600,
                ),
              ),
            ),
          ),
          // Dataset Shared with Show IPs
          Card(
            margin:
                const EdgeInsets.symmetric(
              vertical: 6,
            ),
            elevation: 0,
            shape:
                RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(8),
              side: BorderSide(
                color: Colors.grey.shade200,
              ),
            ),
            child: Column(
              children: [
                ListTile(
                  dense: true,
                  leading: Icon(
                    _distributionStep.index >=
                            DistributionStep
                                .dataShared
                                .index
                        ? Icons.check_circle
                        : Icons.done_all,
                    color:
                        _distributionStep.index >=
                                DistributionStep
                                    .dataShared
                                    .index
                            ? Colors.green
                            : Colors.grey,
                  ),
                  title: const Text(
                    'Dataset Shared',
                    style: TextStyle(
                      fontWeight:
                          FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    _distributionStep.index >=
                            DistributionStep
                                .dataShared
                                .index
                        ? 'Complete'
                        : 'In progress',
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          Colors.grey.shade600,
                    ),
                  ),
                  trailing: TextButton(
                    onPressed:
                        _ackedDataIps.isEmpty
                            ? null
                            : () => setState(
                                  () =>
                                      _showDataIps =
                                          !_showDataIps,
                                ),
                    child: Text(
                      _showDataIps
                          ? 'Hide IPs'
                          : 'Show IPs',
                    ),
                  ),
                ),
                if (
                  _showDataIps &&
                  _ackedDataIps.isNotEmpty
                )
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment
                              .start,
                      children:
                          _ackedDataIps
                              .map(
                                (ip) => Padding(
                                  padding:
                                      const EdgeInsets
                                          .symmetric(
                                    vertical: 2,
                                  ),
                                  child: Text(
                                    ip,
                                    style: TextStyle(
                                      color: Colors
                                          .grey
                                          .shade800,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Job status summary
          if (_jobProgress.isNotEmpty)
            Card(
              margin:
                  const EdgeInsets.symmetric(
                vertical: 6,
              ),
              elevation: 0,
              shape:
                  RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(8),
                side: BorderSide(
                  color: Colors.grey.shade200,
                ),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Job Status',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall,
                    ),
                    const SizedBox(height: 8),
                    ..._jobProgress.entries
                        .map((e) {
                      final jid = e.key;
                      final data =
                          e.value
                              as Map<String,
                                  dynamic>;
                      final total =
                          (data['total'] is int)
                              ? data['total']
                                  as int
                              : int.tryParse(
                                    '${data['total']}',
                                  ) ??
                                  0;
                      final completed =
                          (data['completed']
                                  is int)
                              ? data['completed']
                                  as int
                              : int.tryParse(
                                    '${data['completed']}',
                                  ) ??
                                  0;
                      final assigned =
                          (data['assigned'] is int)
                              ? data['assigned']
                                  as int
                              : int.tryParse(
                                    '${data['assigned']}',
                                  ) ??
                                  0;
                      final available =
                          (data['available'] is int)
                              ? data['available']
                                  as int
                              : int.tryParse(
                                    '${data['available']}',
                                  ) ??
                                  0;
                      final progress =
                          total > 0
                              ? (completed /
                                  total)
                              : 0.0;
                      return Padding(
                        padding:
                            const EdgeInsets.only(
                          bottom: 8,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment
                                        .start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _shortenId(
                                            jid,
                                          ),
                                          style:
                                              const TextStyle(
                                            fontWeight:
                                                FontWeight
                                                    .w600,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(
                                        width: 8,
                                      ),
                                      Chip(
                                        label:
                                            Text(
                                          '$completed/$total',
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(
                                    height: 6,
                                  ),
                                  ClipRRect(
                                    borderRadius:
                                        BorderRadius
                                            .circular(
                                      6,
                                    ),
                                    child:
                                        LinearProgressIndicator(
                                      value:
                                          progress,
                                      minHeight:
                                          8,
                                      backgroundColor:
                                          Colors
                                              .grey
                                              .shade200,
                                      color:
                                          Colors.black,
                                    ),
                                  ),
                                  const SizedBox(
                                    height: 6,
                                  ),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Wrap(
                                          spacing: 6,
                                          runSpacing:
                                              6,
                                          children: [
                                            Chip(
                                              label:
                                                  Text(
                                                'Completed: $completed',
                                              ),
                                            ),
                                            if (
                                              assigned >
                                                  0
                                            )
                                              Chip(
                                                label:
                                                    Text(
                                                  'Assigned: $assigned',
                                                ),
                                              ),
                                            if (
                                              available >
                                                  0
                                            )
                                              Chip(
                                                label:
                                                    Text(
                                                  'Available: $available',
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(
                                        width: 8,
                                      ),
                                      FittedBox(
                                        child: Row(
                                          children: [
                                            if (
                                              total >
                                                      0 &&
                                                  completed >=
                                                      total
                                            )
                                              Padding(
                                                padding:
                                                    const EdgeInsets
                                                        .only(
                                                  right:
                                                      8.0,
                                                ),
                                                child:
                                                    ElevatedButton(
                                                  onPressed:
                                                      () => Navigator.of(
                                                    context,
                                                  ).push(
                                                    MaterialPageRoute(
                                                      builder:
                                                          (_) =>
                                                              ResultsGalleryScreen(
                                                        serverBase:
                                                            widget
                                                                .mqttService
                                                                .serverUrl,
                                                        jobId:
                                                            jid,
                                                      ),
                                                    ),
                                                  ),
                                                  style:
                                                      ElevatedButton.styleFrom(
                                                    padding:
                                                        const EdgeInsets
                                                            .symmetric(
                                                      horizontal:
                                                          12,
                                                    ),
                                                  ),
                                                  child:
                                                      const Text(
                                                    'Show results',
                                                  ),
                                                ),
                                              ),
                                            if (
                                              completed >
                                                      0 &&
                                                  !(total >
                                                          0 &&
                                                      completed >=
                                                          total)
                                            )
                                              OutlinedButton(
                                                onPressed:
                                                    () => Navigator.of(
                                                  context,
                                                ).push(
                                                  MaterialPageRoute(
                                                    builder:
                                                        (_) =>
                                                            ResultsGalleryScreen(
                                                      serverBase:
                                                          widget
                                                              .mqttService
                                                              .serverUrl,
                                                      jobId:
                                                          jid,
                                                    ),
                                                  ),
                                                ),
                                                style:
                                                    OutlinedButton.styleFrom(
                                                  padding:
                                                      const EdgeInsets
                                                          .symmetric(
                                                    horizontal:
                                                        12,
                                                  ),
                                                ),
                                                child:
                                                    const Text(
                                                  'Show current',
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                    const SizedBox(height: 8),
                    const Text(
                      'Per-client assigned units',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_perClientQueues.isEmpty)
                      Text(
                        'No assignments yet',
                        style: TextStyle(
                          color:
                              Colors.grey.shade600,
                        ),
                      )
                    else
                      Column(
                        crossAxisAlignment:
                            CrossAxisAlignment
                                .start,
                        children:
                            _perClientQueues
                                .entries
                                .map((e) {
                          final clientId =
                              e.key;
                          final units =
                              e.value
                                  .map(
                                    (u) =>
                                        u['unitIndex'],
                                  )
                                  .toList();
                          // compute completed count
                          // for this client across
                          // recent results for visible jobs
                          int completedByClient =
                              0;
                          try {
                            for (
                              final jobResults
                                  in _recentResults
                                      .values
                            ) {
                              for (
                                final r
                                    in jobResults
                              ) {
                                try {
                                  if (
                                    (r['i']
                                            as String) ==
                                        clientId
                                  ) {
                                    completedByClient++;
                                  }
                                } catch (_) {}
                              }
                            }
                          } catch (_) {}
                          // try to resolve a friendly
                          // device name from connected clients
                          String displayName;
                          try {
                            final match =
                                widget.mqttService
                                    .connectedClients
                                    .firstWhere(
                                      (c) =>
                                          c.clientId ==
                                          clientId,
                                    );
                            displayName =
                                match.deviceName
                                        .isNotEmpty
                                    ? match.deviceName
                                    : clientId;
                          } catch (_) {
                            // fallback to full
                            // clientId when no friendly
                            // name is available
                            displayName = clientId;
                          }
                          return Padding(
                            padding:
                                const EdgeInsets
                                    .symmetric(
                              vertical: 6,
                            ),
                            child: Row(
                              children: [
                                // left column:
                                // device name + done chip
                                SizedBox(
                                  width: 250,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Tooltip(
                                          message:
                                              displayName,
                                          child: Text(
                                            displayName,
                                            style:
                                                const TextStyle(
                                              fontWeight:
                                                  FontWeight
                                                      .w600,
                                            ),
                                            maxLines: 1,
                                            overflow:
                                                TextOverflow
                                                    .ellipsis,
                                          ),
                                        ),
                                      ),
                                      if (
                                        completedByClient >
                                            0
                                      )
                                        Padding(
                                          padding:
                                              const EdgeInsets
                                                  .only(
                                            left: 6.0,
                                          ),
                                          child: Chip(
                                            label:
                                                Text(
                                              'Done: '
                                              '$completedByClient',
                                              style:
                                                  const TextStyle(
                                                fontSize:
                                                    12,
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(
                                  width: 16,
                                ),
                                // units take remaining space
                                Expanded(
                                  child: Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children:
                                        units
                                            .map<
                                                Widget>(
                                              (u) =>
                                                  Chip(
                                                label:
                                                    Text(
                                                  u.toString(),
                                                  style:
                                                      const TextStyle(
                                                    fontSize:
                                                        12,
                                                  ),
                                                ),
                                              ),
                                            )
                                            .toList(),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    const SizedBox(height: 10),
                    // Note: actions to view results
                    // are shown inline in the per-job
                    // progress row above.
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            ),
          // Model warmup card
          Card(
            margin:
                const EdgeInsets.symmetric(
              vertical: 6,
            ),
            elevation: 0,
            shape:
                RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(8),
              side: BorderSide(
                color: Colors.grey.shade200,
              ),
            ),
            child: ListTile(
              dense: true,
              leading: Icon(
                _modelWarmupReceived
                    ? Icons.check_circle
                    : Icons.science,
                color:
                    _modelWarmupReceived
                        ? Colors.green
                        : Colors.grey,
              ),
              title: const Text(
                'Model Warmup',
                style: TextStyle(
                  fontWeight:
                      FontWeight.w600,
                ),
              ),
              subtitle:
                  _modelWarmupReceived
                      ? Text(
                          'ttproc: '
                          '${_modelWarmupTtprocMs?.toStringAsFixed(1)} '
                          'ms · bw: '
                          '${_modelWarmupBwKbps?.toStringAsFixed(1)} '
                          'kB/s',
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                Colors.grey.shade600,
                          ),
                        )
                      : Text(
                          'Waiting for warmup reports',
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                Colors.grey.shade600,
                          ),
                        ),
            ),
          ),
        ],
      ),
    );
  }
  @override
  Widget build(
    BuildContext context,
  ) {
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        bottom:
            MediaQuery.of(context)
                .viewInsets
                .bottom,
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Padding(
            padding:
                const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 20,
            ),
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment
                                .start,
                        children: [
                          Text(
                            'Hosting Session',
                            style:
                                Theme.of(context)
                                    .textTheme
                                    .headlineMedium,
                          ),
                          const SizedBox(
                            height: 8,
                          ),
                          if (_isStarting)
                            const Row(
                              children: [
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(
                                    strokeWidth:
                                        2,
                                  ),
                                ),
                                SizedBox(
                                  width: 8,
                                ),
                                Text(
                                  'Starting session...',
                                  style: TextStyle(
                                    color:
                                        Colors.grey,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            )
                          else if (
                            widget.mqttService
                                .isBrokerRunning
                          )
                            const Row(
                              children: [
                                Icon(
                                  Icons.circle,
                                  color:
                                      Colors.green,
                                  size: 12,
                                ),
                                SizedBox(
                                  width: 8,
                                ),
                                Text(
                                  'Session is live',
                                  style:
                                      TextStyle(
                                    color:
                                        Colors.green,
                                    fontSize: 14,
                                    fontWeight:
                                        FontWeight
                                            .w500,
                                  ),
                                ),
                              ],
                            )
                          else
                            Text(
                              'Session not started',
                              style: TextStyle(
                                color:
                                    Colors.grey
                                        .shade600,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(
                      width: 16,
                    ),
                    TextButton(
                      onPressed:
                          _stopHosting,
                      style:
                          TextButton.styleFrom(
                        shape:
                            RoundedRectangleBorder(
                          side: BorderSide(
                            color:
                                Colors.grey.shade300,
                          ),
                          borderRadius:
                              BorderRadius.circular(
                            8,
                          ),
                        ),
                      ),
                      child:
                          const Text(
                        'Stop Session',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Connected participants + selectors + submit
          Padding(
            padding:
                const EdgeInsets.symmetric(
              horizontal: 24,
            ),
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                const Divider(
                  height: 1,
                ),
                const SizedBox(
                  height: 20,
                ),
                Row(
                  children: [
                    Text(
                      'Connected Participants',
                      style:
                          Theme.of(context)
                              .textTheme
                              .titleLarge,
                    ),
                    const Spacer(),
                    Container(
                      padding:
                          const EdgeInsets
                              .symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration:
                          BoxDecoration(
                        color: Colors.black,
                        borderRadius:
                            BorderRadius.circular(
                          12,
                        ),
                      ),
                      child: Text(
                        '${widget.mqttService.connectedClientsCount}',
                        style:
                            const TextStyle(
                          color: Colors.white,
                          fontWeight:
                              FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(
                  height: 16,
                ),
                if (
                  widget.mqttService
                      .connectedClients
                      .isEmpty
                )
                  Text(
                    'No participants yet. '
                    'Share your device IP for others to join.',
                    style: TextStyle(
                      color:
                          Colors.grey.shade600,
                      fontSize: 14,
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints:
                        const BoxConstraints(
                      maxHeight: 300,
                    ),
                    child:
                        SingleChildScrollView(
                      child: Column(
                        children:
                            widget.mqttService
                                .connectedClients
                                .map(
                                  (c) => Padding(
                                    padding:
                                        const EdgeInsets
                                            .only(
                                      bottom: 8,
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 6,
                                          height: 6,
                                          decoration:
                                              const BoxDecoration(
                                            color:
                                                Colors
                                                    .green,
                                            shape:
                                                BoxShape
                                                    .circle,
                                          ),
                                        ),
                                        const SizedBox(
                                          width: 12,
                                        ),
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment
                                                  .start,
                                          children: [
                                            Text(
                                              c.deviceName,
                                              style:
                                                  const TextStyle(
                                                fontSize:
                                                    14,
                                                fontWeight:
                                                    FontWeight
                                                        .w500,
                                              ),
                                            ),
                                            const SizedBox(
                                              height: 2,
                                            ),
                                            Text(
                                              c.ipAddress,
                                              style:
                                                  TextStyle(
                                                fontSize:
                                                    12,
                                                color:
                                                    Colors
                                                        .grey
                                                        .shade600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                      ),
                    ),
                  ),
                const SizedBox(
                  height: 20,
                ),
                if (
                  widget.mqttService
                      .connectedClients
                      .isNotEmpty
                ) ...[
                  const Divider(
                    height: 1,
                  ),
                  const SizedBox(
                    height: 16,
                  ),
                  // Model selector
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment
                                  .start,
                          children: [
                            const Text(
                              'Model',
                              style:
                                  TextStyle(
                                fontWeight:
                                    FontWeight
                                        .bold,
                              ),
                            ),
                            const SizedBox(
                              height: 6,
                            ),
                            Text(
                              _selectedModelFile
                                      ?.path
                                      .split('/')
                                      .last ??
                                  'No model selected',
                              style: TextStyle(
                                color:
                                    Colors.grey
                                        .shade700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(
                        width: 12,
                      ),
                      ElevatedButton(
                        onPressed:
                            _pickModel,
                        child:
                            const Text(
                          'Select Model',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(
                    height: 12,
                  ),
                  // Dataset selector
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment
                                  .start,
                          children: [
                            const Text(
                              'Dataset',
                              style:
                                  TextStyle(
                                fontWeight:
                                    FontWeight
                                        .bold,
                              ),
                            ),
                            const SizedBox(
                              height: 6,
                            ),
                            Text(
                              _selectedDatasetFile
                                      ?.path
                                      .split('/')
                                      .last ??
                                  'No dataset selected',
                              style: TextStyle(
                                color:
                                    Colors.grey
                                        .shade700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(
                        width: 12,
                      ),
                      ElevatedButton(
                        onPressed:
                            _pickDataset,
                        child:
                            const Text(
                          'Select Dataset',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(
                    height: 12,
                  ),
                  // Scheduling algorithm selector
                  Row(
                    crossAxisAlignment:
                        CrossAxisAlignment
                            .center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment
                                  .start,
                          children: [
                            const Text(
                              'Scheduling Algorithm',
                              style:
                                  TextStyle(
                                fontWeight:
                                    FontWeight
                                        .bold,
                              ),
                            ),
                            const SizedBox(
                              height: 6,
                            ),
                            Text(
                              distributionManager
                                  .schedulerType
                                  .description,
                              style: TextStyle(
                                color:
                                    Colors.grey
                                        .shade600,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(
                        width: 12,
                      ),
                      SchedulingAlgorithmSelector(
                        selected:
                            distributionManager
                                .schedulerType,
                        onChanged:
                            _changeSchedulingAlgorithm,
                      ),
                    ],
                  ),
                  const SizedBox(
                    height: 12,
                  ),
                  // Units per assignment selector
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Units per assignment',
                          style:
                              TextStyle(
                            fontWeight:
                                FontWeight
                                    .bold,
                          ),
                        ),
                      ),
                      const SizedBox(
                        width: 12,
                      ),
                      DropdownButton<int>(
                        value:
                            _unitsPerAssignment,
                        items: [
                          1,
                          2,
                          3,
                          4,
                          5,
                          10,
                        ]
                            .map(
                              (v) =>
                                  DropdownMenuItem(
                                value: v,
                                child:
                                    Text('$v'),
                              ),
                            )
                            .toList(),
                        onChanged: (v) =>
                            setState(
                          () =>
                              _unitsPerAssignment =
                                  v ?? 2,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(
                    height: 16,
                  ),
                  SizedBox(
                    width: double.infinity,
                    child:
                        ElevatedButton.icon(
                      onPressed:
                          _isProcessingDistribution
                              ? null
                              : _submitDistribution,
                      icon: const Icon(
                        Icons.send,
                        color: Colors.white,
                      ),
                      label: Text(
                        _isProcessingDistribution
                            ? 'Processing...'
                            : 'Submit & Start Distribution',
                        style:
                            const TextStyle(
                          color: Colors.white,
                          fontWeight:
                              FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      style:
                          ElevatedButton.styleFrom(
                        backgroundColor:
                            Colors.black,
                        foregroundColor:
                            Colors.white,
                        padding:
                            const EdgeInsets
                                .symmetric(
                          vertical: 14,
                        ),
                        shape:
                            RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(
                            8,
                          ),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ),
                  const SizedBox(
                    height: 16,
                  ),
                ],
                const Divider(
                  height: 1,
                ),
              ],
            ),
          ),
          // Distribution progress UI
          _buildDistributionProgress(),
          // FileShareWidget and message log
          // when broker is running
          if (
            widget.mqttService
                    .isBrokerRunning &&
                widget.mqttService
                    .connectedClients
                    .isNotEmpty
          ) ...[
            Padding(
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 24,
              ),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const SizedBox(
                    height: 20,
                  ),
                  FileShareWidget(
                    mqttService:
                        widget.mqttService,
                  ),
                ],
              ),
            ),
          ],
          if (
            widget.showMessageLog &&
            widget.mqttService
                .isBrokerRunning
          ) ...[
            Padding(
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 24,
              ),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  const SizedBox(
                    height: 20,
                  ),
                  Row(
                    children: [
                      Text(
                        'Send Message',
                        style:
                            Theme.of(context)
                                .textTheme
                                .titleLarge,
                      ),
                      const Spacer(),
                    ],
                  ),
                  const SizedBox(
                    height: 16,
                  ),
                  Row(
                    children: [
                      const Text(
                        'Topic:',
                        style:
                            TextStyle(
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                      const SizedBox(
                        width: 10,
                      ),
                      DropdownButton<String>(
                        value:
                            _selectedTopic,
                        items: [
                          widget.mqttService
                              .defaultTopic,
                          widget.mqttService
                              .shareTopic,
                        ]
                            .map(
                              (t) =>
                                  DropdownMenuItem(
                                value: t,
                                child:
                                    Text(t),
                              ),
                            )
                            .toList(),
                        onChanged:
                            _onTopicChanged,
                      ),
                    ],
                  ),
                  const SizedBox(
                    height: 12,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller:
                              _messageController,
                          decoration:
                              const InputDecoration(
                            hintText:
                                'Enter your message...',
                            contentPadding:
                                EdgeInsets
                                    .symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          onSubmitted:
                              (_) =>
                                  _publishMessage(),
                        ),
                      ),
                      const SizedBox(
                        width: 12,
                      ),
                      ElevatedButton(
                        onPressed:
                            _publishMessage,
                        child:
                            const Text(
                          'Send',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(
                    height: 20,
                  ),
                  const Divider(
                    height: 1,
                  ),
                  const SizedBox(
                    height: 20,
                  ),
                  ConstrainedBox(
                    constraints:
                        const BoxConstraints(
                      minHeight: 200,
                      maxHeight: 400,
                    ),
                    child: MessageLog(
                      mqttService:
                          widget.mqttService,
                      scrollController:
                          _scrollController,
                    ),
                  ),
                  const SizedBox(
                    height: 20,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
