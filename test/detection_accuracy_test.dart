import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/metrics/detection_accuracy.dart';

NormBox gt(String c, double x1, double y1, double x2, double y2) => NormBox(c, x1, y1, x2, y2);
NormBox det(String c, double conf, double x1, double y1, double x2, double y2) =>
    NormBox(c, x1, y1, x2, y2, conf: conf);

void main() {
  group('parsing', () {
    test('COCO names list has the 80 classes in order', () {
      expect(DetectionAccuracy.cocoNames.length, 80);
      expect(DetectionAccuracy.cocoNames.first, 'person');
      expect(DetectionAccuracy.cocoNames.last, 'toothbrush');
    });

    test('YOLO label lines become corner boxes with class names', () {
      final boxes = DetectionAccuracy.parseYoloLabels('0 0.5 0.5 0.2 0.4\n\n7 0.1 0.1 0.2 0.2\nbad line\n', ['person', 'car']);
      expect(boxes.length, 2);
      expect(boxes[0].cls, 'person');
      expect(boxes[0].x1, closeTo(0.4, 1e-9));
      expect(boxes[0].y2, closeTo(0.7, 1e-9));
      expect(boxes[1].cls, '7', reason: 'an index with no name is kept as its number');
    });

    test('data.yaml names in all three spellings', () {
      expect(DetectionAccuracy.parseDataYaml("path: x\nnames: ['cat', \"dog\"]\n"), ['cat', 'dog']);
      expect(DetectionAccuracy.parseDataYaml('names:\n  - cat\n  - dog\nnc: 2\n'), ['cat', 'dog']);
      expect(DetectionAccuracy.parseDataYaml('names:\n  0: cat\n  1: dog\ntrain: images\n'), ['cat', 'dog']);
      expect(DetectionAccuracy.parseDataYaml('nc: 2\n'), isEmpty);
    });

    test('detections need normalised corners', () {
      final boxes = DetectionAccuracy.parseDetections([
        {'className': 'cat', 'confidence': 0.9, 'x1_norm': 0.1, 'y1_norm': 0.1, 'x2_norm': 0.3, 'y2_norm': 0.3},
        {'className': 'dog', 'confidence': 0.8, 'x1': 10, 'y1': 10, 'x2': 30, 'y2': 30},
        'not a map',
      ]);
      expect(boxes.single.cls, 'cat');
      expect(boxes.single.conf, 0.9);
    });
  });

  group('evaluate', () {
    test('perfect detections score 1', () {
      final r = DetectionAccuracy.evaluate(
        {'a.jpg': [gt('cat', 0.1, 0.1, 0.5, 0.5)], 'b.jpg': [gt('dog', 0.2, 0.2, 0.6, 0.6)]},
        {'a.jpg': [det('Cat', 0.9, 0.1, 0.1, 0.5, 0.5)], 'b.jpg': [det('dog', 0.8, 0.21, 0.2, 0.6, 0.6)]},
      );
      expect(r.images, 2);
      expect(r.precision, 1);
      expect(r.recall, 1);
      expect(r.map50, 1);
    });

    test('a confident false positive ranked first halves AP', () {
      final r = DetectionAccuracy.evaluate(
        {'a.jpg': [gt('cat', 0.1, 0.1, 0.5, 0.5)]},
        {'a.jpg': [det('cat', 0.9, 0.6, 0.6, 0.9, 0.9), det('cat', 0.8, 0.1, 0.1, 0.5, 0.5)]},
      );
      expect(r.apByClass['cat'], closeTo(0.5, 1e-9));
      expect(r.precision, 0.5);
      expect(r.recall, 1);
    });

    test('duplicates, wrong classes and misses are penalised', () {
      final r = DetectionAccuracy.evaluate(
        {'a.jpg': [gt('cat', 0.1, 0.1, 0.5, 0.5), gt('dog', 0.5, 0.5, 0.9, 0.9)]},
        {
          'a.jpg': [
            det('cat', 0.9, 0.1, 0.1, 0.5, 0.5),
            det('cat', 0.7, 0.1, 0.1, 0.5, 0.5), // duplicate of a matched box
            det('bird', 0.6, 0.5, 0.5, 0.9, 0.9), // right place, wrong class
          ],
        },
      );
      expect(r.precision, closeTo(1 / 3, 1e-9));
      expect(r.recall, 0.5, reason: 'the dog was never found');
      expect(r.apByClass['cat'], 1);
      expect(r.apByClass['dog'], 0);
      expect(r.map50, 0.5);
    });

    test('labelled images that were not processed are left out', () {
      final r = DetectionAccuracy.evaluate(
        {'a.jpg': [gt('cat', 0.1, 0.1, 0.5, 0.5)], 'b.jpg': [gt('cat', 0.1, 0.1, 0.5, 0.5)]},
        {'a.jpg': [det('cat', 0.9, 0.1, 0.1, 0.5, 0.5)]},
      );
      expect(r.images, 1);
      expect(r.recall, 1);
    });
  });
}
