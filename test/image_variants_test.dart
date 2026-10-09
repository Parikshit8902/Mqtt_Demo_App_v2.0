import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mqtt_demo/services/utils/image_variants.dart';
import 'package:path/path.dart' as p;

Uint8List jpeg(int w, int h) {
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgb(x, y, (x * 7) % 256, (y * 5) % 256, ((x + y) * 3) % 256);
    }
  }
  return img.encodeJpg(im, quality: 95);
}

void main() {
  test('labels', () {
    expect(ImageVariant.original.label, 'original');
    expect(const ImageVariant(maxSide: 640, quality: 70).label, 'max640px_q70');
    expect(const ImageVariant(quality: 50).label, 'q50');
  });

  test('downscales the longer side and keeps the aspect ratio', () {
    final out = transformImage(jpeg(800, 400), const ImageVariant(maxSide: 200));
    final d = img.decodeImage(out)!;
    expect([d.width, d.height], [200, 100]);
    final tall = img.decodeImage(transformImage(jpeg(300, 600), const ImageVariant(maxSide: 150)))!;
    expect([tall.width, tall.height], [75, 150]);
  });

  test('lower quality gives fewer bytes; nothing to do returns the input', () {
    final src = jpeg(320, 240);
    expect(transformImage(src, const ImageVariant(quality: 30)).length, lessThan(src.length));
    expect(identical(transformImage(src, const ImageVariant(maxSide: 1000)), src), isTrue, reason: 'already small enough');
    final notImage = Uint8List.fromList([1, 2, 3]);
    expect(identical(transformImage(notImage, const ImageVariant(maxSide: 10)), notImage), isTrue);
  });

  test('cache makes each copy once and serves originals as they are', () async {
    final tmp = Directory.systemTemp.createTempSync('variants_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final srcDir = Directory(p.join(tmp.path, 'id_0'))..createSync();
    final a = File(p.join(srcDir.path, 'entry_0'))..writeAsBytesSync(jpeg(400, 300));
    final b = File(p.join(srcDir.path, 'entry_1'))..writeAsBytesSync(jpeg(300, 400));
    final cache = ImageVariantCache(() async => Directory(p.join(tmp.path, 'cache')));
    const v = ImageVariant(maxSide: 100, quality: 60);

    expect((await cache.fileFor(a, ImageVariant.original)).path, a.path);
    await cache.prepare([a, b], v);
    final fa = await cache.fileFor(a, v);
    expect(fa.path, isNot(a.path));
    final d = img.decodeImage(await fa.readAsBytes())!;
    expect([d.width, d.height], [100, 75]);
    final again = await cache.fileFor(a, v);
    expect(again.path, fa.path);
    await cache.clear();
    expect(fa.existsSync(), isFalse);
  });
}
