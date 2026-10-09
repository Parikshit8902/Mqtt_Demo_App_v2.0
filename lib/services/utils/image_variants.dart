import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// How the host serves dataset images: as they are, or scaled down and/or
/// re-encoded as JPEG. Smaller images cost less to send and to run, and may
/// cost accuracy; this setting lets runs measure that trade-off.
class ImageVariant {
  /// Longest side in pixels; 0 = keep the original size.
  final int maxSide;

  /// JPEG quality 1-100; 0 = keep the original encoding when the size is
  /// unchanged (a resized image is always re-encoded, at 90 unless set).
  final int quality;

  const ImageVariant({this.maxSide = 0, this.quality = 0});

  static const original = ImageVariant();

  bool get isOriginal => maxSide <= 0 && quality <= 0;

  /// Short label for file names, exports and the report.
  String get label => isOriginal
      ? 'original'
      : [if (maxSide > 0) 'max${maxSide}px', if (quality > 0) 'q$quality'].join('_');

  @override
  bool operator ==(Object other) => other is ImageVariant && other.maxSide == maxSide && other.quality == quality;

  @override
  int get hashCode => Object.hash(maxSide, quality);
}

/// [bytes] transformed per [v]. Returns the input unchanged when it is not an
/// image the decoder knows, or when nothing would change.
Uint8List transformImage(Uint8List bytes, ImageVariant v) {
  if (v.isOriginal) return bytes;
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    // Some decoders throw on bytes they cannot read instead of returning null.
  }
  if (decoded == null) return bytes;
  final longest = max(decoded.width, decoded.height);
  final resize = v.maxSide > 0 && longest > v.maxSide;
  if (!resize && v.quality <= 0) return bytes;
  final out = resize
      ? img.copyResize(
          decoded,
          width: decoded.width >= decoded.height ? v.maxSide : null,
          height: decoded.height > decoded.width ? v.maxSide : null,
          interpolation: img.Interpolation.average,
        )
      : decoded;
  return img.encodeJpg(out, quality: v.quality > 0 ? v.quality : 90);
}

/// Transformed copies of dataset images, made once per image and setting
/// (in a background isolate) and kept on disk, so serving one is a file read.
class ImageVariantCache {
  final Future<Directory> Function() _root;
  Future<Directory>? _rootReady;

  // "<source path>|<variant label>" -> the file to serve (in flight or done)
  final Map<String, Future<File>> _files = {};

  ImageVariantCache(this._root);

  /// The file to serve for [source] under [v]: [source] itself when [v] is
  /// the original, else the transformed copy (made on first use).
  Future<File> fileFor(File source, ImageVariant v) {
    if (v.isOriginal) return Future.value(source);
    final key = '${source.path}|${v.label}';
    final made = _files[key] ??= _make(source, v);
    // A failed transform is not cached, so a later request tries again.
    made.catchError((Object _) {
      _files.remove(key);
      return source;
    });
    return made;
  }

  /// Makes every copy for [sources] up front (one isolate for all), so the
  /// first worker to ask for an image does not wait for its conversion.
  Future<void> prepare(List<File> sources, ImageVariant v) async {
    if (v.isOriginal) return;
    final todo = sources.where((s) => !_files.containsKey('${s.path}|${v.label}')).toList();
    if (todo.isEmpty) return;
    final dir = await _dirFor(v);
    final pairs = [for (final s in todo) (s.path, _outPath(dir, s))];
    final batch = _transformInIsolate(pairs, v);
    for (final (src, out) in pairs) {
      _files['$src|${v.label}'] = batch.then((_) => File(out));
    }
    await batch;
  }

  Future<void> clear() async {
    _files.clear();
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

  Future<File> _make(File source, ImageVariant v) async {
    final out = _outPath(await _dirFor(v), source);
    await _transformInIsolate([(source.path, out)], v);
    return File(out);
  }

  Future<Directory> _dirFor(ImageVariant v) async {
    final root = await (_rootReady ??= _prepareRoot());
    final dir = Directory(p.join(root.path, v.label));
    await dir.create(recursive: true);
    return dir;
  }

  // An extracted entry's name is unique within its extraction folder, so the
  // folder name keeps copies from different datasets apart.
  String _outPath(Directory dir, File source) =>
      p.join(dir.path, '${p.basename(p.dirname(source.path))}_${p.basename(source.path)}');

  Future<Directory> _prepareRoot() async {
    final dir = await _root();
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    return dir;
  }
}

/// Writes each `(source, out)` pair's transformed image in a background
/// isolate. Top level, so the closure carries only these arguments.
Future<void> _transformInIsolate(List<(String, String)> pairs, ImageVariant v) {
  return Isolate.run(() {
    for (final (src, out) in pairs) {
      File(out).writeAsBytesSync(transformImage(File(src).readAsBytesSync(), v));
    }
  });
}
