import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// One file from a ZIP, extracted to disk.
class ZipEntryFile {
  /// Name inside the archive.
  final String name;

  /// Uncompressed size in bytes.
  final int size;

  /// Where the extracted bytes live.
  final String path;

  const ZipEntryFile(this.name, this.size, this.path);
}

/// Extracts each shared ZIP once and serves its entries from disk.
///
/// The host used to read and decode the whole dataset ZIP for every image a
/// worker fetched, so every measured download time included the host's
/// decoding work, and that time is what the schedulers learn link speed from.
/// Now a ZIP is extracted once (in a background isolate) the first time it is
/// needed, and each request is a plain file read.
///
/// Entries are written under numbered names, never their archive paths, so an
/// entry called `../x` cannot escape the cache directory.
class ZipEntryCache {
  /// Resolves the directory the cache may use; it is wiped on first use, so
  /// extractions left over from an earlier run do not pile up.
  final Future<Directory> Function() _root;

  Future<Directory>? _rootReady;
  int _extractions = 0;

  // key -> entries by name, in archive order (in flight or done)
  final Map<String, Future<Map<String, ZipEntryFile>>> _byKey = {};

  // key -> the file version that was extracted (path, size, mtime)
  final Map<String, String> _stamps = {};

  ZipEntryCache(this._root);

  /// How many times a ZIP has actually been extracted (for tests and logs).
  int get extractions => _extractions;

  /// All file entries of [zip], extracting it on first use. [key] identifies
  /// the shared file (its id); if the file at that key has changed since it
  /// was extracted, it is extracted again.
  Future<Map<String, ZipEntryFile>> entries(String key, File zip) async {
    final stat = await zip.stat();
    final stamp =
        '${zip.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}';

    if (_stamps[key] != stamp) {
      _stamps[key] = stamp;
      _byKey[key] = _extract(key, zip.path);
    }

    try {
      return await _byKey[key]!;
    } catch (_) {
      // Let a later request try again rather than caching the failure.
      if (_stamps[key] == stamp) {
        _stamps.remove(key);
        _byKey.remove(key);
      }
      rethrow;
    }
  }

  /// One entry of [zip] by its name in the archive, or null if there is none.
  Future<ZipEntryFile?> entry(String key, File zip, String name) async {
    return (await entries(key, zip))[name];
  }

  /// Forget every extraction and delete the extracted files.
  Future<void> clear() async {
    _byKey.clear();
    _stamps.clear();
    final ready = _rootReady;
    if (ready == null) return;
    try {
      final dir = await ready;
      if (await dir.exists()) {
        await for (final child in dir.list()) {
          await child.delete(recursive: true);
        }
      }
    } catch (_) {
      // Best effort: the OS clears the temp directory eventually.
    }
  }

  Future<Map<String, ZipEntryFile>> _extract(String key, String zipPath) async {
    final root = await (_rootReady ??= _prepareRoot());
    final safeKey = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final outDir = Directory(p.join(root.path, '${safeKey}_${_extractions++}'));
    await outDir.create(recursive: true);

    final outPath = outDir.path;
    final files = await Isolate.run(() => _extractSync(zipPath, outPath));

    final byName = <String, ZipEntryFile>{};
    for (final f in files) {
      // Same as the old firstWhere lookup: the first entry with a name wins.
      byName.putIfAbsent(f.name, () => f);
    }
    return byName;
  }

  Future<Directory> _prepareRoot() async {
    final dir = await _root();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);
    return dir;
  }
}

List<ZipEntryFile> _extractSync(String zipPath, String outDir) {
  // Reading through a file stream keeps the compressed archive on disk; only
  // the entries are held in memory while they are written out.
  final input = InputFileStream(zipPath);
  try {
    final archive = ZipDecoder().decodeBuffer(input);
    final out = <ZipEntryFile>[];
    var i = 0;
    for (final af in archive.files) {
      if (!af.isFile) continue;
      final data = af.content as List<int>;
      final path = p.join(outDir, 'entry_${i++}');
      File(path).writeAsBytesSync(data);
      out.add(ZipEntryFile(af.name, data.length, path));
    }
    return out;
  } finally {
    input.closeSync();
  }
}
