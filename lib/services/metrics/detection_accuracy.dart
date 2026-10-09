import 'dart:math';

/// A box with corners normalised to 0..1 of the image's width and height.
class NormBox {
  final String cls;
  final double x1, y1, x2, y2;

  /// Detector confidence; 1 for ground truth.
  final double conf;

  const NormBox(this.cls, this.x1, this.y1, this.x2, this.y2, {this.conf = 1});

  double get area => max(0.0, x2 - x1) * max(0.0, y2 - y1);

  double iou(NormBox o) {
    final w = min(x2, o.x2) - max(x1, o.x1);
    final h = min(y2, o.y2) - max(y1, o.y1);
    if (w <= 0 || h <= 0) return 0;
    final inter = w * h;
    final union = area + o.area - inter;
    return union > 0 ? inter / union : 0;
  }
}

/// How well detections match labelled boxes over a set of images.
class AccuracyResult {
  /// Images that had a label file and a result.
  final int images;
  final int labelledBoxes;
  final int detectedBoxes;

  /// Over all classes, a detection counting as correct when it overlaps an
  /// unmatched labelled box of its class with IoU >= the threshold.
  final double precision;
  final double recall;

  /// Mean of [apByClass] (classes with at least one labelled box).
  final double map50;
  final Map<String, double> apByClass;

  const AccuracyResult({
    required this.images,
    required this.labelledBoxes,
    required this.detectedBoxes,
    required this.precision,
    required this.recall,
    required this.map50,
    required this.apByClass,
  });

  Map<String, dynamic> toJson() => {
        'images': images,
        'labelled_boxes': labelledBoxes,
        'detected_boxes': detectedBoxes,
        'precision': _r(precision),
        'recall': _r(recall),
        'map50': _r(map50),
        'ap_by_class': {for (final e in apByClass.entries) e.key: _r(e.value)},
      };

  static double _r(double v) => double.parse(v.toStringAsFixed(4));
}

/// Scores object detections against YOLO-format labels.
class DetectionAccuracy {
  /// Class names of the COCO dataset in index order, used when the dataset
  /// does not name its classes (the default YOLO models are COCO-trained).
  static const List<String> cocoNames = [
    'person', 'bicycle', 'car', 'motorcycle', 'airplane', 'bus', 'train', 'truck', 'boat',
    'traffic light', 'fire hydrant', 'stop sign', 'parking meter', 'bench', 'bird', 'cat', 'dog',
    'horse', 'sheep', 'cow', 'elephant', 'bear', 'zebra', 'giraffe', 'backpack', 'umbrella',
    'handbag', 'tie', 'suitcase', 'frisbee', 'skis', 'snowboard', 'sports ball', 'kite',
    'baseball bat', 'baseball glove', 'skateboard', 'surfboard', 'tennis racket', 'bottle',
    'wine glass', 'cup', 'fork', 'knife', 'spoon', 'bowl', 'banana', 'apple', 'sandwich',
    'orange', 'broccoli', 'carrot', 'hot dog', 'pizza', 'donut', 'cake', 'chair', 'couch',
    'potted plant', 'bed', 'dining table', 'toilet', 'tv', 'laptop', 'mouse', 'remote',
    'keyboard', 'cell phone', 'microwave', 'oven', 'toaster', 'sink', 'refrigerator', 'book',
    'clock', 'vase', 'scissors', 'teddy bear', 'hair drier', 'toothbrush',
  ];

  /// Class names from a `classes.txt` / `*.names` file (one per line).
  static List<String> parseNamesFile(String text) =>
      text.split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  /// Class names from the `names:` entry of a YOLO `data.yaml`, in any of its
  /// three spellings: `[a, b]`, a `- a` list, or a `0: a` map. Empty if none.
  static List<String> parseDataYaml(String text) {
    final lines = text.split(RegExp(r'\r?\n'));
    final i = lines.indexWhere((l) => RegExp(r'^names\s*:').hasMatch(l));
    if (i < 0) return const [];
    String unquote(String s) => s.trim().replaceAll(RegExp(r'''^['"]|['"]$'''), '').trim();

    final inline = lines[i].substring(lines[i].indexOf(':') + 1).trim();
    if (inline.startsWith('[')) {
      final body = inline.replaceAll(RegExp(r'^\[|\]$'), '');
      return body.split(',').map(unquote).where((s) => s.isNotEmpty).toList();
    }
    final byIndex = <int, String>{};
    final listed = <String>[];
    for (final l in lines.skip(i + 1)) {
      if (l.trim().isEmpty) continue;
      if (!l.startsWith(' ') && !l.startsWith('\t') && !l.startsWith('-')) break;
      final t = l.trim();
      final m = RegExp(r'^(\d+)\s*:\s*(.+)$').firstMatch(t);
      if (m != null) {
        byIndex[int.parse(m.group(1)!)] = unquote(m.group(2)!);
      } else if (t.startsWith('-')) {
        listed.add(unquote(t.substring(1)));
      }
    }
    if (byIndex.isNotEmpty) {
      final n = byIndex.keys.reduce(max) + 1;
      return [for (var k = 0; k < n; k++) byIndex[k] ?? '$k'];
    }
    return listed;
  }

  /// Boxes from a YOLO label file: one `class cx cy w h` line per object,
  /// all normalised. A class index with no name is kept as its number.
  static List<NormBox> parseYoloLabels(String text, List<String> names) {
    final out = <NormBox>[];
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final p = line.trim().split(RegExp(r'\s+'));
      if (p.length < 5) continue;
      final c = int.tryParse(p[0]);
      final v = [for (final s in p.sublist(1, 5)) double.tryParse(s)];
      if (c == null || v.contains(null)) continue;
      final cx = v[0]!, cy = v[1]!, w = v[2]!, h = v[3]!;
      final cls = c >= 0 && c < names.length ? names[c] : '$c';
      out.add(NormBox(cls, cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2));
    }
    return out;
  }

  /// Boxes from a worker's detections (the YOLO plugin's `boxes` maps). Only
  /// entries with normalised corners can be compared; others are skipped.
  static List<NormBox> parseDetections(List<dynamic>? detections) {
    final out = <NormBox>[];
    for (final d in detections ?? const []) {
      if (d is! Map) continue;
      double? n(String k) => (d[k] as num?)?.toDouble();
      final x1 = n('x1_norm'), y1 = n('y1_norm'), x2 = n('x2_norm'), y2 = n('y2_norm');
      if (x1 == null || y1 == null || x2 == null || y2 == null) continue;
      final cls = (d['className'] ?? d['class'] ?? d['label'] ?? '').toString();
      out.add(NormBox(cls, x1, y1, x2, y2, conf: n('confidence') ?? 0));
    }
    return out;
  }

  /// Precision, recall and mAP at IoU [iouThreshold] over the images in
  /// [labels] that also have an entry in [detections]. Class names are
  /// compared case-insensitively. AP is the area under the all-point
  /// interpolated precision/recall curve (PASCAL VOC 2010 and later).
  static AccuracyResult evaluate(
    Map<String, List<NormBox>> labels,
    Map<String, List<NormBox>> detections, {
    double iouThreshold = 0.5,
  }) {
    String key(String c) => c.trim().toLowerCase();
    final images = labels.keys.where(detections.containsKey).toList();

    final gtCount = <String, int>{};
    for (final img in images) {
      for (final g in labels[img]!) {
        gtCount[key(g.cls)] = (gtCount[key(g.cls)] ?? 0) + 1;
      }
    }

    // Every detection, best first, judged against the labels of its image.
    final all = <({String img, NormBox box})>[
      for (final img in images)
        for (final d in detections[img]!) (img: img, box: d),
    ]..sort((a, b) => b.box.conf.compareTo(a.box.conf));

    final used = <String, Set<int>>{for (final img in images) img: {}};
    final hitsByClass = <String, List<bool>>{};
    var tp = 0;
    for (final d in all) {
      final c = key(d.box.cls);
      final gts = labels[d.img]!;
      var best = -1;
      var bestIou = iouThreshold;
      for (var i = 0; i < gts.length; i++) {
        if (key(gts[i].cls) != c || used[d.img]!.contains(i)) continue;
        final o = d.box.iou(gts[i]);
        if (o >= bestIou) {
          bestIou = o;
          best = i;
        }
      }
      final hit = best >= 0;
      if (hit) {
        used[d.img]!.add(best);
        tp++;
      }
      hitsByClass.putIfAbsent(c, () => []).add(hit);
    }

    final ap = <String, double>{
      for (final c in gtCount.keys) c: _averagePrecision(hitsByClass[c] ?? const [], gtCount[c]!),
    };
    final totalGt = gtCount.values.fold(0, (a, b) => a + b);
    return AccuracyResult(
      images: images.length,
      labelledBoxes: totalGt,
      detectedBoxes: all.length,
      precision: all.isEmpty ? 0 : tp / all.length,
      recall: totalGt == 0 ? 0 : tp / totalGt,
      map50: ap.isEmpty ? 0 : ap.values.reduce((a, b) => a + b) / ap.length,
      apByClass: ap,
    );
  }

  /// [hits] are one class's detections, best first, each true if it matched.
  static double _averagePrecision(List<bool> hits, int gt) {
    if (gt == 0) return 0;
    final recall = <double>[0];
    final precision = <double>[1];
    var tp = 0;
    for (var i = 0; i < hits.length; i++) {
      if (hits[i]) tp++;
      recall.add(tp / gt);
      precision.add(tp / (i + 1));
    }
    // Make precision non-increasing from the right, then sum the area under it.
    for (var i = precision.length - 2; i >= 0; i--) {
      precision[i] = max(precision[i], precision[i + 1]);
    }
    var area = 0.0;
    for (var i = 1; i < recall.length; i++) {
      area += (recall[i] - recall[i - 1]) * precision[i];
    }
    return area;
  }
}
