import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:mqtt_demo/widgets/bounding_box_painter.dart';

class ModelManagementScreen extends StatefulWidget {
  const ModelManagementScreen({super.key});

  @override
  State<ModelManagementScreen> createState() => _ModelManagementScreenState();
}

class _ModelManagementScreenState extends State<ModelManagementScreen> {
  Future<Directory> _getPublicBaseDirectory() async {
    // Keep model assets in this app's private documents directory.  A shared
    // Downloads folder may already contain unrelated `models` or `datasets`
    // directories, which previously made a fresh install look downloaded.
    final documentsDirectory = await getApplicationDocumentsDirectory();
    return Directory(path.join(documentsDirectory.path, 'model_management'));
  }

  Future<ui.Image> _loadImage(File file) async {
    final data = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(data);
    final frame = await codec.getNextFrame();
    return frame.image;
  }
  // Download states
  bool _isModelDownloading = false;
  bool _isDatasetDownloading = false;
  double _modelProgress = 0.0;
  double _datasetProgress = 0.0;
  String _modelStatus = 'Not downloaded';
  String _datasetStatus = 'Not downloaded';

  // File paths
  String? _modelPath;
  String? _datasetPath;
  List<String> _imagePaths = [];
  int _selectedImageCount = 5;

  // Advanced settings
  double _confidenceThreshold = 0.25;
  double _iouThreshold = 0.45;
  int _maxDetections = 100;
  bool _useGPU = true;
  bool _useParallelProcessing = true;
  int _selectedCores = 4; // Default to 4 cores
  int _batchSize = 1;
  String _actualDeviceUsed = 'Detecting...';

  // Inference results - now grouped by image
  List<Map<String, dynamic>> _inferenceResults = [];
  bool _isRunningInference = false;
  int _currentProcessingIndex = 0;
  Duration _inferenceDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _checkExistingFiles();
  }

  Future<void> _checkExistingFiles() async {
    print('[DEBUG] Checking for existing model and dataset files...');
    final baseDir = await _getPublicBaseDirectory();
    final modelFile = File(path.join(baseDir.path, 'models', 'yolo11n.tflite'));
    final datasetDir = Directory(path.join(baseDir.path, 'datasets', 'coco128'));

    final modelIsValid =
        await modelFile.exists() && await modelFile.length() > 1024 * 1024;
    if (modelIsValid) {
      print('[DEBUG] Model file found at: \'${modelFile.path}\'');
      _modelPath = modelFile.path;
      _modelStatus = 'Downloaded';
    } else {
      _modelPath = null;
      _modelStatus = 'Not downloaded';
      print('[DEBUG] Model file not found.');
    }

    final datasetImages = await _findDatasetImages(datasetDir);
    if (datasetImages.isNotEmpty) {
      print('[DEBUG] Dataset directory found at: \'${datasetDir.path}\'');
      _datasetPath = datasetDir.path;
      _datasetStatus = 'Downloaded';
      _imagePaths = datasetImages;
      if (_selectedImageCount > _imagePaths.length) {
        _selectedImageCount = _imagePaths.length;
      }
    } else {
      _datasetPath = null;
      _datasetStatus = 'Not downloaded';
      _imagePaths = [];
      print('[DEBUG] Dataset directory not found.');
    }

    if (mounted) setState(() {});
  }

  Future<List<String>> _findDatasetImages(Directory datasetDir) async {
    final trainDir = Directory(path.join(datasetDir.path, 'images', 'train2017'));
    if (!await trainDir.exists()) return [];

    const imageExtensions = {'.jpg', '.jpeg', '.png', '.webp'};
    final images = <String>[];
    await for (final entity in trainDir.list()) {
      if (entity is File && imageExtensions.contains(path.extension(entity.path).toLowerCase())) {
        images.add(entity.path);
      }
    }
    images.sort();
    return images;
  }

  /// Downloads a release asset atomically. GitHub release downloads are served
  /// through a redirecting CDN, which can occasionally reset a mobile socket.
  /// Retrying the streamed download prevents an intermittent reset from being
  /// reported as a permanent failed model/dataset download.
  Future<void> _downloadWithRetry({
    required Uri uri,
    required File destination,
    required void Function(double progress) onProgress,
    required void Function(String status) onAttempt,
    int maxAttempts = 4,
  }) async {
    final client = http.Client();
    final temporaryFile = File('${destination.path}.part');
    Object? lastError;

    try {
      await destination.parent.create(recursive: true);

      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          if (await temporaryFile.exists()) {
            await temporaryFile.delete();
          }

          onAttempt(
            attempt == 1
                ? 'Downloading...'
                : 'Retrying download ($attempt of $maxAttempts)...',
          );

          final request = http.Request('GET', uri)
            ..headers['Accept'] = 'application/octet-stream'
            ..headers['User-Agent'] = 'mqtt-demo/1.0';
          final response = await client
              .send(request)
              .timeout(const Duration(seconds: 45));

          if (response.statusCode != HttpStatus.ok) {
            throw HttpException(
              'Server returned HTTP ${response.statusCode}',
              uri: uri,
            );
          }

          final expectedLength = response.contentLength;
          var receivedLength = 0;
          final sink = temporaryFile.openWrite();
          try {
            await for (final chunk in response.stream) {
              sink.add(chunk);
              receivedLength += chunk.length;
              if (expectedLength != null && expectedLength > 0) {
                onProgress(receivedLength / expectedLength);
              }
            }
          } finally {
            await sink.close();
          }

          if (receivedLength == 0 ||
              (expectedLength != null && receivedLength != expectedLength)) {
            throw const HttpException('Download ended before all bytes arrived');
          }

          if (await destination.exists()) {
            await destination.delete();
          }
          await temporaryFile.rename(destination.path);
          onProgress(1);
          return;
        } catch (error) {
          lastError = error;
          if (attempt < maxAttempts) {
            await Future<void>.delayed(Duration(seconds: attempt));
          }
        }
      }
    } finally {
      client.close();
      if (await temporaryFile.exists()) {
        await temporaryFile.delete();
      }
    }

    throw Exception(
      'Unable to download after $maxAttempts attempts. '
      'Please check the device connection and try again. (${lastError ?? 'unknown error'})',
    );
  }

  Future<void> _downloadModel() async {
    setState(() {
      _isModelDownloading = true;
      _modelProgress = 0.0;
      _modelStatus = 'Downloading...';
    });

    try {
      final baseDir = await _getPublicBaseDirectory();
      final modelsDir = Directory(path.join(baseDir.path, 'models'));
      if (!await modelsDir.exists()) {
        await modelsDir.create(recursive: true);
      }
      final file = File(path.join(modelsDir.path, 'yolo11n.tflite'));
      print('[DEBUG] Downloading YOLO model to: ${file.path}');
      await _downloadWithRetry(
        uri: Uri.parse(
          'https://github.com/ultralytics/yolo-flutter-app/releases/download/v0.2.0/yolo11n.tflite',
        ),
        destination: file,
        onProgress: (progress) {
          if (mounted) setState(() => _modelProgress = progress);
        },
        onAttempt: (status) {
          if (mounted) setState(() => _modelStatus = status);
        },
      );

      if (await file.length() > 1024 * 1024) {
        _modelPath = file.path;
        _modelStatus = 'Downloaded';
        print('[DEBUG] Model downloaded successfully.');
      } else {
        await file.delete();
        _modelStatus = 'Download failed: model file is incomplete';
      }
    } catch (e) {
      _modelStatus = 'Error: $e';
      print('[DEBUG] Model download error: $e');
    }

    setState(() {
      _isModelDownloading = false;
      _modelProgress = 1.0;
    });
  }

  Future<void> _downloadDataset() async {
    setState(() {
      _isDatasetDownloading = true;
      _datasetProgress = 0.0;
      _datasetStatus = 'Downloading...';
    });

    try {
      final baseDir = await _getPublicBaseDirectory();
      final datasetsDir = Directory(path.join(baseDir.path, 'datasets'));
      if (!await datasetsDir.exists()) {
        await datasetsDir.create(recursive: true);
      }
      final zipFile = File(path.join(datasetsDir.path, 'coco128.zip'));
      print('[DEBUG] Downloading COCO128 dataset to: ${zipFile.path}');
      await _downloadWithRetry(
        uri: Uri.parse(
          'https://github.com/ultralytics/assets/releases/download/v0.0.0/coco128.zip',
        ),
        destination: zipFile,
        onProgress: (progress) {
          if (mounted) setState(() => _datasetProgress = progress);
        },
        onAttempt: (status) {
          if (mounted) setState(() => _datasetStatus = status);
        },
      );

      if (await zipFile.length() > 0) {
        print('[DEBUG] Dataset zip downloaded. Extracting...');
        // Extract ZIP into datasetsDir to avoid double coco128 nesting
        final bytes = zipFile.readAsBytesSync();
        final archive = ZipDecoder().decodeBytes(bytes);

        for (final file in archive) {
          final filename = path.join(datasetsDir.path, file.name.replaceAll('/', Platform.pathSeparator));
          if (file.isFile) {
            final data = file.content as List<int>;
            final outFile = File(filename);
            outFile.createSync(recursive: true);
            outFile.writeAsBytesSync(data);
          } else {
            Directory(filename).createSync(recursive: true);
          }
        }

        // Set _datasetPath to the correct extracted coco128 directory
        final extractDir = Directory(path.join(datasetsDir.path, 'coco128'));
        final images = await _findDatasetImages(extractDir);
        if (images.isEmpty) {
          _datasetPath = null;
          _datasetStatus = 'Download failed: dataset images were not found';
        } else {
          _datasetPath = extractDir.path;
          _imagePaths = images;
          _datasetStatus = 'Downloaded and extracted';
          if (_selectedImageCount > _imagePaths.length) {
            _selectedImageCount = _imagePaths.length;
          }
          print('[DEBUG] Dataset extracted to: $_datasetPath');
        }
      }
    } catch (e) {
      _datasetStatus = 'Error: $e';
      print('[DEBUG] Dataset download/extract error: $e');
    }

    setState(() {
      _isDatasetDownloading = false;
      _datasetProgress = 1.0;
    });
  }

  Future<void> _runInference() async {
    if (_modelPath == null) {
      print('[DEBUG] Cannot run inference: Model not loaded.');
      setState(() {
        _inferenceResults = [];
        _isRunningInference = false;
      });
      return;
    }
    if (_imagePaths.isEmpty) {
      print('[DEBUG] Cannot run inference: No images found.');
      setState(() {
        _inferenceResults = [];
        _isRunningInference = false;
      });
      return;
    }

    setState(() {
      _isRunningInference = true;
      _inferenceResults = [];
      _currentProcessingIndex = 0;
      _inferenceDuration = Duration.zero; // Reset duration
    });

    final startTime = DateTime.now(); // Start timing

    try {
      print('[DEBUG] Initializing YOLO for inference...');
      
      // Get available CPU cores for optimal performance
      final cpuCores = Platform.numberOfProcessors;
      print('[DEBUG] Available CPU cores: $cpuCores');
      print('[DEBUG] GPU enabled: $_useGPU');
      print('[DEBUG] Parallel processing: $_useParallelProcessing');
      if (_useParallelProcessing) {
        print('[DEBUG] Selected CPU cores: $_selectedCores');
      }
      
      // Determine which device will be used and processing strategy
      String deviceToUse = 'CPU';
      bool shouldUseParallel = false;
      
      if (_useGPU) {
        deviceToUse = 'GPU (if available, otherwise CPU)';
        // When GPU is enabled, we typically don't need parallel CPU processing
        // as GPU provides better performance for ML tasks
        shouldUseParallel = false;
        print('[DEBUG] GPU mode: Using GPU for inference (parallel CPU disabled for optimal performance)');
      } else if (_useParallelProcessing && _selectedCores > 1) {
        deviceToUse = 'CPU (Parallel with $_selectedCores cores)';
        shouldUseParallel = true;
        print('[DEBUG] CPU mode: Using parallel processing with $_selectedCores cores');
      } else {
        deviceToUse = 'CPU (Single core)';
        shouldUseParallel = false;
        print('[DEBUG] CPU mode: Using single core processing');
      }
      
      setState(() {
        _actualDeviceUsed = deviceToUse;
      });
      
      // Initialize YOLO with basic configuration
      // Note: ultralytics_yolo automatically detects and uses GPU if available
      // when _useGPU is true. CPU cores are utilized automatically for optimization
      final yolo = YOLO(
        modelPath: _modelPath!,
        task: YOLOTask.detect,
        useGpu: _useGPU,
      );
      
      // Check what methods are available on the YOLO object
      print('[DEBUG] YOLO object methods: ${yolo.runtimeType}');
      
      await yolo.loadModel(); // Load the model before predicting
      
      final actualImageCount = _selectedImageCount > _imagePaths.length ? _imagePaths.length : _selectedImageCount;
      final selectedImages = _imagePaths.take(actualImageCount).toList();
      print('[DEBUG] Running inference on ${selectedImages.length} images...');

      // Use parallel processing only when appropriate (CPU mode with multiple cores)
      if (shouldUseParallel) {
        await _runParallelInference(yolo, selectedImages);
      } else {
        await _runSequentialInference(yolo, selectedImages);
      }
    } catch (e) {
      print('[DEBUG] Inference error: $e');
      setState(() {
        _inferenceResults = [];
      });
    }

    // Final summary
    final imagesWithDetections = _inferenceResults.where((result) => (result['detections'] as List).isNotEmpty).length;
    final endTime = DateTime.now(); // End timing
    _inferenceDuration = endTime.difference(startTime); // Calculate duration
    
    print('[DEBUG] Inference completed: ${_inferenceResults.length} images processed, $imagesWithDetections with detections');
    print('[DEBUG] Total inference time: ${_inferenceDuration.inMilliseconds}ms (${_inferenceDuration.inSeconds}s)');

    setState(() {
      _isRunningInference = false;
      _currentProcessingIndex = 0;
    });
  }

  Future<void> _runSequentialInference(YOLO yolo, List<String> imagePaths) async {
    print('[DEBUG] Running sequential inference...');
    
    for (int i = 0; i < imagePaths.length; i++) {
      setState(() {
        _currentProcessingIndex = i + 1;
      });

      final imagePath = imagePaths[i];
      final imageBytes = await File(imagePath).readAsBytes();
      
      // Note: Device configuration is handled automatically by ultralytics_yolo
      // GPU will be used if available, otherwise CPU with available cores
      final result = await yolo.predict(
        imageBytes,
        confidenceThreshold: _confidenceThreshold,
        iouThreshold: _iouThreshold,
      );
      print('[DEBUG] Inference result for $imagePath: $result');
      
      // Check what other metrics are available in the result
      print('[DEBUG] Available result keys: ${result.keys.toList()}');
      
      // Always add result, even if no detections found
      final detections = _applyDetectionSettings(result['boxes']);
      print('[DEBUG] Image ${i + 1}/${imagePaths.length}: ${imagePath.split('/').last} - ${detections.length} detections');
      _inferenceResults.add({
        'imagePath': imagePath,
        'detections': detections,
      });
    }
  }

  Future<void> _runParallelInference(YOLO yolo, List<String> imagePaths) async {
    final concurrency = math.min(_selectedCores, _batchSize);
    print('[DEBUG] Running parallel inference with $concurrency concurrent images...');
    
    // Split images into chunks for parallel processing
    final chunkSize = concurrency.clamp(1, imagePaths.length).toInt();
    final chunks = <List<String>>[];
    
    for (int i = 0; i < imagePaths.length; i += chunkSize) {
      final end = (i + chunkSize < imagePaths.length) ? i + chunkSize : imagePaths.length;
      chunks.add(imagePaths.sublist(i, end));
    }
    
    print('[DEBUG] Split into ${chunks.length} chunks for parallel processing');
    
    // Process chunks sequentially but images within chunks in parallel
    for (int chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++) {
      final chunk = chunks[chunkIndex];
      print('[DEBUG] Processing chunk ${chunkIndex + 1}/${chunks.length} with ${chunk.length} images');
      
      // Process images in this chunk in parallel
      final futures = chunk.map((imagePath) async {
        final imageBytes = await File(imagePath).readAsBytes();
        final result = await yolo.predict(
          imageBytes,
          confidenceThreshold: _confidenceThreshold,
          iouThreshold: _iouThreshold,
        );
        final detections = _applyDetectionSettings(result['boxes']);
        
        print('[DEBUG] Parallel inference result keys: ${result.keys.toList()}');
        print('[DEBUG] Parallel inference: ${imagePath.split('/').last} - ${detections.length} detections');
        
        return {
          'imagePath': imagePath,
          'detections': detections,
        };
      });
      
      // Wait for all images in this chunk to complete
      final chunkResults = await Future.wait(futures);
      
      // Add results to main list
      _inferenceResults.addAll(chunkResults);
      
      // Update progress
      setState(() {
        _currentProcessingIndex = (chunkIndex + 1) * chunkSize;
      });
    }
    
    // Ensure final progress is accurate
    setState(() {
      _currentProcessingIndex = imagePaths.length;
    });
  }

  /// Applies the post-processing controls exposed by this screen. The plugin
  /// returns already-decoded boxes but does not accept these controls through
  /// its single-image `predict` API, so they must be applied here.
  List<Map<String, dynamic>> _applyDetectionSettings(dynamic rawBoxes) {
    if (rawBoxes is! List) return [];

    final boxes = rawBoxes
        .whereType<Map>()
        .map((box) => Map<String, dynamic>.from(box))
        .where((box) => _confidenceOf(box) >= _confidenceThreshold)
        .toList()
      ..sort((a, b) => _confidenceOf(b).compareTo(_confidenceOf(a)));

    final kept = <Map<String, dynamic>>[];
    for (final candidate in boxes) {
      final candidateClass = _classKey(candidate);
      final overlapsKeptBox = kept.any(
        (accepted) =>
            _classKey(accepted) == candidateClass &&
            _intersectionOverUnion(accepted, candidate) > _iouThreshold,
      );
      if (!overlapsKeptBox) {
        kept.add(candidate);
        if (kept.length == _maxDetections) break;
      }
    }
    return kept;
  }

  double _confidenceOf(Map<String, dynamic> detection) {
    final value = detection['confidence'];
    return value is num ? value.toDouble() : 0;
  }

  String _classKey(Map<String, dynamic> detection) =>
      (detection['classId'] ?? detection['className'] ?? detection['label'] ?? '').toString();

  double _intersectionOverUnion(
    Map<String, dynamic> first,
    Map<String, dynamic> second,
  ) {
    double number(Map<String, dynamic> box, String key) {
      final value = box[key];
      return value is num ? value.toDouble() : 0;
    }

    final firstLeft = number(first, 'x1');
    final firstTop = number(first, 'y1');
    final firstRight = number(first, 'x2');
    final firstBottom = number(first, 'y2');
    final secondLeft = number(second, 'x1');
    final secondTop = number(second, 'y1');
    final secondRight = number(second, 'x2');
    final secondBottom = number(second, 'y2');

    final intersectionWidth = math.max(0, math.min(firstRight, secondRight) - math.max(firstLeft, secondLeft));
    final intersectionHeight = math.max(0, math.min(firstBottom, secondBottom) - math.max(firstTop, secondTop));
    final intersection = intersectionWidth * intersectionHeight;
    final firstArea = math.max(0, firstRight - firstLeft) * math.max(0, firstBottom - firstTop);
    final secondArea = math.max(0, secondRight - secondLeft) * math.max(0, secondBottom - secondTop);
    final union = firstArea + secondArea - intersection;
    return union <= 0 ? 0 : intersection / union;
  }

  String _formatDuration(Duration duration) {
    if (duration.inSeconds < 1) {
      return '${duration.inMilliseconds}ms';
    } else if (duration.inMinutes < 1) {
      return '${duration.inSeconds}.${(duration.inMilliseconds % 1000 ~/ 100)}s';
    } else {
      return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
    }
  }

  String _formatPerformanceMetrics() {
    if (_inferenceResults.isEmpty || _inferenceDuration == Duration.zero) {
      return 'No performance data available';
    }
    
    final totalImages = _inferenceResults.length;
    final avgTimePerImage = _inferenceDuration.inMilliseconds / totalImages;
    final imagesPerSecond = totalImages / _inferenceDuration.inMilliseconds * 1000;
    
    return '${_formatDuration(_inferenceDuration)} total (${avgTimePerImage.toStringAsFixed(1)}ms per image, ${imagesPerSecond.toStringAsFixed(2)} img/s)';
  }

  Future<void> _exportResults() async {
    try {
      final baseDir = await _getPublicBaseDirectory();
      final exportDir = Directory(path.join(baseDir.path, 'exports'));
      if (!await exportDir.exists()) {
        await exportDir.create(recursive: true);
      }

      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final exportFile = File(path.join(exportDir.path, 'detection_results_$timestamp.json'));

      final exportData = {
        'timestamp': timestamp,
        'model': _modelPath?.split('/').last,
        'settings': {
          'confidenceThreshold': _confidenceThreshold,
          'iouThreshold': _iouThreshold,
          'maxDetections': _maxDetections,
          'useGPU': _useGPU,
          'batchSize': _batchSize,
          'parallelProcessing': _useParallelProcessing,
          'selectedCores': _selectedCores,
          'actualDeviceUsed': _actualDeviceUsed,
        },
        'performance': {
          'totalDurationMs': _inferenceDuration.inMilliseconds,
          'totalDurationFormatted': _formatDuration(_inferenceDuration),
          'imagesProcessed': _inferenceResults.length,
          'averageTimePerImageMs': _inferenceResults.isNotEmpty ? _inferenceDuration.inMilliseconds / _inferenceResults.length : 0,
          'imagesPerSecond': _inferenceResults.isNotEmpty ? _inferenceResults.length / _inferenceDuration.inSeconds : 0,
        },
        'results': _inferenceResults.map((result) {
          return {
            'image': result['imagePath'].split('/').last,
            'detections': result['detections'],
          };
        }).toList(),
      };

      await exportFile.writeAsString(jsonEncode(exportData));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Results exported to: ${exportFile.path}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Model Management'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Model Download Section
            const Text('YOLO Model Download', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Status: $_modelStatus'),
            const SizedBox(height: 8),
            if (_isModelDownloading)
              LinearProgressIndicator(value: _modelProgress)
            else
              ElevatedButton(
                onPressed: _modelPath == null ? _downloadModel : null,
                child: const Text('Download YOLO11n Model'),
              ),
            const SizedBox(height: 24),

            // Dataset Download Section
            const Text('COCO128 Dataset Download', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Status: $_datasetStatus'),
            const SizedBox(height: 8),
            if (_isDatasetDownloading)
              LinearProgressIndicator(value: _datasetProgress)
            else
              ElevatedButton(
                onPressed: _datasetPath == null ? _downloadDataset : null,
                child: const Text('Download COCO128 Dataset'),
              ),
            const SizedBox(height: 16),

            // Dataset Information Section
            if (_imagePaths.isNotEmpty) ...[
              const Text('Dataset Information', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Total Images Available: ${_imagePaths.length}'),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Images to Process:'),
                  Expanded(
                    child: Slider(
                      value: _selectedImageCount.toDouble(),
                      min: 1,
                      max: _imagePaths.length.toDouble(),
                      divisions: _imagePaths.length > 1 ? _imagePaths.length - 1 : 1,
                      label: _selectedImageCount.toString(),
                      onChanged: (value) => setState(() => _selectedImageCount = value.toInt()),
                    ),
                  ),
                  Text(_selectedImageCount.toString()),
                ],
              ),
              const SizedBox(height: 24),
            ],

            // Advanced Settings Section
            const Text('Advanced Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            // Confidence Threshold
            Row(
              children: [
                const Text('Confidence Threshold:'),
                Expanded(
                  child: Slider(
                    value: _confidenceThreshold,
                    min: 0.0,
                    max: 1.0,
                    divisions: 20,
                    label: _confidenceThreshold.toStringAsFixed(2),
                    onChanged: (value) => setState(() => _confidenceThreshold = value),
                  ),
                ),
                Text('${(_confidenceThreshold * 100).toInt()}%'),
              ],
            ),
            // IoU Threshold
            Row(
              children: [
                const Text('IoU Threshold:'),
                Expanded(
                  child: Slider(
                    value: _iouThreshold,
                    min: 0.0,
                    max: 1.0,
                    divisions: 20,
                    label: _iouThreshold.toStringAsFixed(2),
                    onChanged: (value) => setState(() => _iouThreshold = value),
                  ),
                ),
                Text('${(_iouThreshold * 100).toInt()}%'),
              ],
            ),
            // Max Detections
            Row(
              children: [
                const Text('Max Detections:'),
                Expanded(
                  child: Slider(
                    value: _maxDetections.toDouble(),
                    min: 1,
                    max: 500,
                    divisions: 50,
                    label: _maxDetections.toString(),
                    onChanged: (value) => setState(() => _maxDetections = value.toInt()),
                  ),
                ),
                Text(_maxDetections.toString()),
              ],
            ),
            Row(
              children: [
                const Text('Batch Size:'),
                Expanded(
                  child: Slider(
                    value: _batchSize.toDouble(),
                    min: 1,
                    max: 16,
                    divisions: 15,
                    label: _batchSize.toString(),
                    onChanged: (value) => setState(() => _batchSize = value.toInt()),
                  ),
                ),
                Text(_batchSize.toString()),
              ],
            ),
            // GPU Toggle
            Row(
              children: [
                const Text('Use GPU:'),
                Switch(
                  value: _useGPU,
                  onChanged: (value) => setState(() => _useGPU = value),
                ),
                if (_useGPU) ...[
                  const SizedBox(width: 8),
                  const Text('(Parallel CPU disabled)', style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ],
            ),
            // Parallel Processing Toggle
            Row(
              children: [
                Text('Parallel Processing:', style: TextStyle(color: _useGPU ? Colors.grey : Colors.black)),
                Switch(
                  value: _useParallelProcessing && !_useGPU, // Automatically disable when GPU is enabled
                  onChanged: _useGPU ? null : (value) => setState(() => _useParallelProcessing = value), // Disable interaction when GPU is on
                ),
                if (_useGPU) ...[
                  const SizedBox(width: 8),
                  const Text('(Disabled when GPU is active)', style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ],
            ),
            // Core Selection (only show when parallel processing is enabled and GPU is disabled)
            if (_useParallelProcessing && !_useGPU) ...[
              Row(
                children: [
                  const Text('CPU Cores to Use:'),
                  Expanded(
                    child: Slider(
                      value: _selectedCores.toDouble(),
                      min: 1,
                      max: Platform.numberOfProcessors.toDouble(),
                      divisions: Platform.numberOfProcessors - 1,
                      label: _selectedCores.toString(),
                      onChanged: (value) => setState(() => _selectedCores = value.toInt()),
                    ),
                  ),
                  Text(_selectedCores.toString()),
                ],
              ),
            ],
            const SizedBox(height: 24),
            if (_isRunningInference) ...[
              Text('Processing image $_currentProcessingIndex of $_selectedImageCount...'),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: _currentProcessingIndex / _selectedImageCount,
              ),
              const SizedBox(height: 16),
            ],
            ElevatedButton(
              onPressed: (_modelPath != null && _datasetPath != null && !_isRunningInference)
                  ? _runInference
                  : null,
              child: _isRunningInference
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text('Run Inference on $_selectedImageCount Images'),
            ),
            // Model Info Section
            if (_modelPath != null) ...[
              const Text('Model Information', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Path: ${_modelPath!.split('/').last}'),
              Text('GPU Enabled: $_useGPU'),
              Text('Parallel Processing: ${_useGPU ? 'Disabled (GPU active)' : _useParallelProcessing ? 'Enabled' : 'Disabled'}'),
              if (_useParallelProcessing && !_useGPU) Text('Selected CPU Cores: $_selectedCores'),
              Text('CPU Cores Available: ${Platform.numberOfProcessors}'),
              Text('Actual Device Used: $_actualDeviceUsed'),
              Text('Confidence Threshold: ${(_confidenceThreshold * 100).toInt()}%'),
              Text('IoU Threshold: ${(_iouThreshold * 100).toInt()}%'),
              Text('Max Detections: $_maxDetections'),
              Text('Batch Size: $_batchSize'),
              if (_inferenceDuration != Duration.zero) ...[
                const SizedBox(height: 8),
                Text('Performance: ${_formatPerformanceMetrics()}', style: const TextStyle(fontWeight: FontWeight.w500)),
              ],
              const SizedBox(height: 24),
            ],
            if (_inferenceResults.isNotEmpty) ...[
              // Export Results Button
              ElevatedButton.icon(
                onPressed: _exportResults,
                icon: const Icon(Icons.save),
                label: const Text('Export Results'),
              ),
              const SizedBox(height: 16),
              const Text('Inference Results', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Images processed: ${_inferenceResults.length} out of $_selectedImageCount selected'),
              Text('Total images available: ${_imagePaths.length}'),
              Builder(
                builder: (context) {
                  final imagesWithDetections = _inferenceResults.where((result) => (result['detections'] as List).isNotEmpty).length;
                  final imagesWithoutDetections = _inferenceResults.length - imagesWithDetections;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Images with detections: $imagesWithDetections'),
                      if (imagesWithoutDetections > 0)
                        Text('Images with no detections: $imagesWithoutDetections'),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _inferenceResults.length,
                itemBuilder: (context, index) {
                  final imageResult = _inferenceResults[index];
                  final imagePath = imageResult['imagePath'];
                  final detections = imageResult['detections'] as List<dynamic>;

                  return Card(
                    margin: const EdgeInsets.only(bottom: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8.0),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Image with bounding boxes
                        FutureBuilder<ui.Image>(
                          future: _loadImage(File(imagePath)),
                          builder: (context, snapshot) {
                            Size? imageSize;
                            if (snapshot.hasData) {
                              final image = snapshot.data!;
                              imageSize = Size(image.width.toDouble(), image.height.toDouble());
                            }

                            return Container(
                              height: 200,
                              width: double.infinity,
                              child: Stack(
                                children: [
                                  // Original image
                                  Image.file(
                                    File(imagePath),
                                    fit: BoxFit.contain,
                                    width: double.infinity,
                                    height: 200,
                                  ),
                                  // Bounding boxes overlay
                                  if (imageSize != null)
                                    CustomPaint(
                                      size: Size(double.infinity, 200),
                                      painter: BoundingBoxPainter(detections, imageSize),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                        // Detection details
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Image: ${imagePath.split('/').last}',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              Text('Detections: ${detections.length}'),
                              const SizedBox(height: 8),
                              ...detections.map((detection) => Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(
                                  '${detection['className']} (${(detection['confidence'] * 100).toStringAsFixed(1)}%)',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              )),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
