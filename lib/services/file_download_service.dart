import 'dart:io';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'message_logger.dart';
import 'file_server_service.dart';

/// Manages file downloads for clients
class FileDownloadService {
  final MessageLogger _logger;
  final Function()? _onStateChanged;
  final Map<String, FileDownloadTask> _downloadTasks = {};

  // Map to track file locks to prevent concurrent operations on the same file
  final Map<String, Completer<void>> _fileLocks = {};

  FileDownloadService(this._logger, {Function()? onStateChanged})
      : _onStateChanged = onStateChanged;

  // Getters
  List<FileDownloadTask> get activeTasks => _downloadTasks.values.toList();

  /// Acquire a lock on a file to prevent concurrent access
  Future<void> _acquireFileLock(String filePath) async {
    if (_fileLocks.containsKey(filePath)) {
      // Wait for existing operation to complete
      _logger.log('🔒 Waiting for file lock on: ${path.basename(filePath)}');
      await _fileLocks[filePath]!.future;
    }

    // Create a new lock
    _fileLocks[filePath] = Completer<void>();
  }

  /// Release a file lock
  void _releaseFileLock(String filePath) {
    if (_fileLocks.containsKey(filePath)) {
      _fileLocks[filePath]!.complete();
      _fileLocks.remove(filePath);
      _logger.log('🔓 Released file lock on: ${path.basename(filePath)}');
    }
  }

  /// Start downloading a file from a share info. This Future completes when
  /// the download finishes (completed/failed/cancelled) and returns the task.
  Future<FileDownloadTask?> downloadFile(FileShareInfo shareInfo) async {
    _logger.log('📥 Starting download for file: ${shareInfo.fileName}');

    try {
      // Create download directory if it doesn't exist
      final downloadsDir = await _getDownloadsDirectory();

      // Generate unique filename to avoid conflicts
      final fileName = shareInfo.fileName;
      final filePath = path.join(downloadsDir.path, fileName);

      // Acquire a lock on the file while creating the task
      await _acquireFileLock(filePath);

      try {
        // Check if file already exists and handle appropriately
        var file = File(filePath);
        if (await file.exists()) {
          // Append number to filename to make it unique
          final baseName = path.basenameWithoutExtension(fileName);
          final extension = path.extension(fileName);
          int counter = 1;
          String newPath;
          do {
            newPath = path.join(downloadsDir.path, '${baseName}_$counter$extension');
            counter++;
          } while (await File(newPath).exists());

          _logger.log('⚠️ File already exists, saving as: ${path.basename(newPath)}');
          file = File(newPath);
        }

        // Create a download task
        final task = FileDownloadTask(
          fileId: shareInfo.fileId,
          fileName: path.basename(file.path),
          fileSize: shareInfo.fileSize,
          url: shareInfo.url,
          destinationFile: file,
          startTime: DateTime.now(),
        );

        // Store task
        _downloadTasks[shareInfo.fileId] = task;
        _onStateChanged?.call();

        // Release the file lock before starting the download
        _releaseFileLock(filePath);

        // Start download and await completion
        await _startDownload(task);
        return task;
      } catch (e) {
        // Make sure to release the lock if there's an error
        _releaseFileLock(filePath);
        rethrow;
      }
    } catch (e) {
      _logger.log('❌ Error starting download: $e');
      return null;
    }
  }

  /// Start the actual download process (streaming, resume-capable)
  Future<void> _startDownload(FileDownloadTask task) async {
    _logger.log('🚀 Starting download from: ${task.url}');

    // Acquire a lock on the destination file
    final filePath = task.destinationFile.path;
    await _acquireFileLock(filePath);

    try {
      // Ensure parent directory exists
      final parentDir = task.destinationFile.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }

      // Check resume position
      int startByte = 0;
      if (await task.destinationFile.exists()) {
        startByte = await task.destinationFile.length();
        if (startByte > 0) {
          _logger.log('⏯️ Resuming download from byte: $startByte');
          task.updateProgress(startByte);
        }
      }

      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(task.url));
        if (startByte > 0) {
          request.headers['Range'] = 'bytes=$startByte-';
        }
        request.headers['Cache-Control'] = 'no-cache';
        request.headers['Pragma'] = 'no-cache';

        final streamedResponse = await client.send(request);

        if (streamedResponse.statusCode == 200 || streamedResponse.statusCode == 206) {
          task.status = DownloadStatus.inProgress;
          _onStateChanged?.call();

          final contentLength = streamedResponse.contentLength ?? task.fileSize;
          if (streamedResponse.statusCode == 200 && startByte > 0) {
            // server returned full file, overwrite existing
            await task.destinationFile.writeAsBytes([], mode: FileMode.write);
            startByte = 0;
            task.updateProgress(0);
          }

          task.expectedBytes = startByte + contentLength;

          // Open file for random access and set position for resume/appending
          final raf = await task.destinationFile.open(mode: FileMode.write);
          await raf.setPosition(startByte);
          try {
            int processedBytes = 0;
            final chunkSize = 64 * 1024; // 64KB

            await for (final chunk in streamedResponse.stream) {
              if (task.status == DownloadStatus.cancelled) {
                _logger.log('🛑 Download cancelled: ${task.fileName}');
                break;
              }

              await raf.writeFrom(chunk);
              processedBytes += chunk.length;
              task.updateProgress(startByte + processedBytes);
              _onStateChanged?.call();

              // Yield to event loop occasionally
              if (processedBytes % (chunkSize * 4) == 0) {
                await Future.delayed(const Duration(milliseconds: 10));
              }
            }
          } finally {
            await raf.close();
          }

          // Finalize
          final finalSize = await task.destinationFile.length();
          final expectedSize = task.fileSize;

          // Calculate final average speed
          final duration = DateTime.now().difference(task.startTime).inMilliseconds / 1000;
          if (duration > 0) {
            task.averageSpeed = task.bytesDownloaded / duration;
          }

          if (finalSize == expectedSize || (expectedSize == 0 && finalSize > 0)) {
            task.status = DownloadStatus.completed;
            task.endTime = DateTime.now();
            _logger.log('✅ Download completed: ${task.fileName}');
            _logger.log('📊 Final file size: ${_formatFileSize(finalSize)}');
          } else if ((finalSize - expectedSize).abs() < 1024) {
            // small difference tolerated
            task.status = DownloadStatus.completed;
            task.endTime = DateTime.now();
            _logger.log('✅ Download completed with minor size diff: ${task.fileName}');
          } else {
            task.status = DownloadStatus.failed;
            task.error = 'File size verification failed';
            _logger.log('⚠️ File size difference: expected $expectedSize bytes, got $finalSize bytes');
          }
        } else {
          task.status = DownloadStatus.failed;
          task.error = 'Server returned ${streamedResponse.statusCode}';
          _logger.log('❌ Download failed with status: ${streamedResponse.statusCode}');
        }
      } finally {
        client.close();
      }
    } catch (e) {
      task.status = DownloadStatus.failed;
      task.error = e.toString();
      _logger.log('❌ Download error: $e');
    } finally {
      // Release the file lock
      _releaseFileLock(filePath);
    }

    _onStateChanged?.call();
  }

  /// Get downloads directory
  Future<Directory> _getDownloadsDirectory() async {
    Directory? directory;

    try {
      if (Platform.isAndroid) {
        // Use downloads directory on Android
        directory = Directory('/storage/emulated/0/Download');
        if (!await directory.exists()) {
          // Fallback to app documents directory
          directory = await getApplicationDocumentsDirectory();
        }
      } else {
        // Use documents directory on iOS and other platforms
        directory = await getApplicationDocumentsDirectory();
      }

      // Create downloads subfolder
      final downloadsDir = Directory('${directory.path}/MqttDownloads');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }

      return downloadsDir;
    } catch (e) {
      _logger.log('⚠️ Error getting downloads directory: $e');
      // Fallback to temporary directory
      final tempDir = await getTemporaryDirectory();
      final downloadsDir = Directory('${tempDir.path}/MqttDownloads');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }
      return downloadsDir;
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
    // Cancel all active downloads
    _downloadTasks.forEach((id, task) {
      if (task.status == DownloadStatus.inProgress) {
        task.status = DownloadStatus.cancelled;
      }
    });
    _downloadTasks.clear();
  }

  /// Cancel a download task and optionally remove partial file
  Future<bool> cancelDownload(String fileId) async {
    _logger.log('🛑 Cancelling download for ID: $fileId');
    if (!_downloadTasks.containsKey(fileId)) {
      _logger.log('⚠️ Download task not found: $fileId');
      return false;
    }

    final task = _downloadTasks[fileId]!;
    task.status = DownloadStatus.cancelled;

    // Try to remove partial file safely
    final filePath = task.destinationFile.path;
    try {
      await _acquireFileLock(filePath);
      try {
        if (await task.destinationFile.exists()) {
          await task.destinationFile.delete();
          _logger.log('🗑️ Deleted partial download file: ${task.fileName}');
        }
      } finally {
        _releaseFileLock(filePath);
      }
    } catch (e) {
      _logger.log('⚠️ Error deleting partial file: $e');
    }

    _downloadTasks.remove(fileId);
    _onStateChanged?.call();
    return true;
  }
}

/// Download status enum
enum DownloadStatus {
  pending,
  inProgress,
  paused,
  completed,
  failed,
  cancelled,
}

/// File download task
class FileDownloadTask {
  final String fileId;
  final String fileName;
  final int fileSize;
  final String url;
  final File destinationFile;
  final DateTime startTime;

  DateTime? endTime;
  DownloadStatus status = DownloadStatus.pending;
  int bytesDownloaded = 0;
  int expectedBytes = 0;
  double downloadSpeed = 0.0; // Current speed in bytes per second
  double averageSpeed = 0.0; // Average speed over entire download
  String? error;

  // Speed calculation helpers
  DateTime _lastSpeedUpdate = DateTime.now();
  int _lastBytesDownloaded = 0;

  FileDownloadTask({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.url,
    required this.destinationFile,
    required this.startTime,
  }) {
    _lastSpeedUpdate = startTime;
  }

  /// Update download progress and calculate speed
  void updateProgress(int newBytesDownloaded) {
    final now = DateTime.now();
    final timeDiff = now.difference(_lastSpeedUpdate).inMilliseconds / 1000.0;

    if (timeDiff > 0.5) { // Update speed every 500ms
      final bytesDiff = newBytesDownloaded - _lastBytesDownloaded;
      downloadSpeed = bytesDiff / timeDiff; // Current speed

      // Calculate average speed
      final totalTimeDiff = now.difference(startTime).inMilliseconds / 1000.0;
      if (totalTimeDiff > 0) {
        averageSpeed = newBytesDownloaded / totalTimeDiff;
      }

      _lastSpeedUpdate = now;
      _lastBytesDownloaded = newBytesDownloaded;
    }

    bytesDownloaded = newBytesDownloaded;
  }

  /// Get elapsed time since download started
  Duration get elapsedTime {
    final endTimeToUse = endTime ?? DateTime.now();
    return endTimeToUse.difference(startTime);
  }

  /// Format elapsed time for display
  String get formattedElapsedTime {
    final duration = elapsedTime;
    final totalSeconds = duration.inSeconds;

    if (totalSeconds < 60) {
      return '${totalSeconds}s';
    } else if (totalSeconds < 3600) {
      final minutes = duration.inMinutes;
      final seconds = totalSeconds % 60;
      return '${minutes}m ${seconds}s';
    } else {
      final hours = duration.inHours;
      final minutes = duration.inMinutes % 60;
      final seconds = totalSeconds % 60;
      return '${hours}h ${minutes}m ${seconds}s';
    }
  }

  /// Get download progress as percentage
  double get progress {
    if (fileSize <= 0) return 0.0;
    return bytesDownloaded / fileSize;
  }

  /// Get estimated time remaining in seconds
  int get estimatedTimeRemaining {
    if (downloadSpeed <= 0) return 0;
    final bytesRemaining = fileSize - bytesDownloaded;
    return (bytesRemaining / downloadSpeed).round();
  }

  /// Format estimated time remaining
  String get formattedTimeRemaining {
    final seconds = estimatedTimeRemaining;
    if (seconds <= 0) return 'unknown';

    if (seconds < 60) {
      return '${seconds}s';
    } else if (seconds < 3600) {
      return '${(seconds / 60).floor()}m ${seconds % 60}s';
    } else {
      final hours = (seconds / 3600).floor();
      final minutes = ((seconds % 3600) / 60).floor();
      return '${hours}h ${minutes}m';
    }
  }

  /// Format current download speed
  String get formattedSpeed {
    return _formatSpeedValue(downloadSpeed);
  }

  /// Format average download speed
  String get formattedAverageSpeed {
    return _formatSpeedValue(averageSpeed);
  }

  /// Helper to format speed values
  String _formatSpeedValue(double speed) {
    if (speed < 1024) {
      return '${speed.toStringAsFixed(1)} B/s';
    } else if (speed < 1024 * 1024) {
      return '${(speed / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${(speed / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
  }
}
