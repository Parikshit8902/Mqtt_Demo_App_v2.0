import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/distribution_manager.dart';
import 'package:mqtt_demo/services/models/assignment.dart';
import 'package:mqtt_demo/services/models/result_dto.dart';
import 'package:mqtt_demo/services/schedulers/scheduler_type.dart';
import 'package:mqtt_demo/services/utils/zip_entry_cache.dart';
import 'package:path/path.dart' as p;

List<Unit> units(int n) =>
    [for (var i = 0; i < n; i++) Unit(unitIndex: i, start: 0, end: 100 * 1024 - 1, fileUrl: 'http://h/$i')];

void main() {
  group('failure reports on the wire', () {
    test('error round-trips and old payloads have none', () {
      final rr = ResultReport(jobId: 'j', clientId: 'c', unitIndex: 3, ttprocMs: 0, bandwidthKbps: 0, error: 'inference: boom');
      final back = ResultReport.fromJson(rr.toJson());
      expect(back.failed, isTrue);
      expect(back.error, 'inference: boom');
      final old = ResultReport.fromJson({'j': 'j', 'i': 'c', 'unit_index': 0, 'ttproc_ms': 1, 'bandwidth_kBps': 1});
      expect(old.failed, isFalse);
      expect(old.toJson().containsKey('error'), isFalse);
    });
  });

  group('DistributionManager failed units', () {
    const a = 'mqtt_client_PixelA_10-0-0-1_10-0-0-11';
    const b = 'mqtt_client_PixelB_10-0-0-1_10-0-0-12';
    var now = 0;
    late DistributionManager dm;

    setUp(() {
      now = 1000;
      dm = DistributionManager(nowMs: () => now, leaseMs: 10000, activeWindowMs: 30000);
      dm.setSchedulerType(SchedulerType.greedy);
      dm.registerJob('j', units(20));
      dm.registerClient(a, ClientEstimate(ttprocMs: 200, bandwidthKbps: 2000));
      dm.registerClient(b, ClientEstimate(ttprocMs: 200, bandwidthKbps: 2000));
    });

    test('a failed unit goes back to the pool at once, not after its lease', () {
      final unit = dm.assignNext('j', a, maxUnits: 1).single;
      expect(dm.markUnitFailed('j', unit.unitIndex, a), UnitFailureOutcome.requeued);
      expect(dm.getClientQueue(a), isEmpty);
      final p = dm.jobProgress('j');
      expect(p['completed'], 0, reason: 'a failure is not a finished image');
      expect(p['assigned'], 0);
      expect(p['available'], 20);
      expect(p['failure_reports'], 1);
      // Well inside the lease, the unit can already go to the other phone.
      now += 1000;
      final got = dm.assignNext('j', b, maxUnits: 20).map((u) => u.unitIndex);
      expect(got, contains(unit.unitIndex));
    });

    test('failures count against the phone, like lease expiries', () {
      final held = dm.assignNext('j', a, maxUnits: 20);
      expect(held.length, greaterThanOrEqualTo(3));
      for (final u in held.take(3)) {
        dm.markUnitFailed('j', u.unitIndex, a);
      }
      final view = dm.clientViews()[a]!;
      expect(view['eligible'], isFalse);
      expect(view['gated_by'], '3 failed units');
      expect(dm.clientViews()[b]!['eligible'], isTrue);
    });

    test('a report from a phone that no longer holds the unit changes nothing', () {
      final unit = dm.assignNext('j', a, maxUnits: 1).single;
      now += 11000; // lease expires, unit goes to b
      dm.touchClient(b);
      final atB = dm.assignNext('j', b, maxUnits: 20).map((u) => u.unitIndex);
      expect(atB, contains(unit.unitIndex));
      expect(dm.markUnitFailed('j', unit.unitIndex, a), UnitFailureOutcome.ignored);
      expect(dm.getClientQueue(b).map((u) => u.unitIndex), contains(unit.unitIndex));
      expect(dm.jobProgress('j')['failure_reports'], 0);
    });

    test('a report for a completed unit is ignored', () {
      final unit = dm.assignNext('j', a, maxUnits: 1).single;
      dm.markUnitComplete('j', unit.unitIndex);
      expect(dm.markUnitFailed('j', unit.unitIndex, a), UnitFailureOutcome.ignored);
      expect(dm.jobProgress('j')['completed'], 1);
    });

    test('reset clears failure counts', () {
      final unit = dm.assignNext('j', a, maxUnits: 1).single;
      dm.markUnitFailed('j', unit.unitIndex, a);
      dm.resetExperiment();
      expect(dm.jobProgress('j')['failure_reports'], 0);
      expect(dm.jobProgress('j')['failed'], 0);
    });
  });

  group('a unit that keeps failing is given up on', () {
    const a = 'mqtt_client_PixelA_10-0-0-1_10-0-0-11';
    var now = 0;
    late DistributionManager dm;

    setUp(() {
      now = 1000;
      dm = DistributionManager(nowMs: () => now, maxUnitAttempts: 3);
      dm.setSchedulerType(SchedulerType.greedy);
      dm.registerJob('j', units(1));
      dm.registerClient(a, ClientEstimate(ttprocMs: 200, bandwidthKbps: 2000));
    });

    test('after maxUnitAttempts reports the job drains instead of looping', () {
      final outcomes = <UnitFailureOutcome>[];
      for (var i = 0; i < 3; i++) {
        final unit = dm.assignNext('j', a, maxUnits: 1).single;
        outcomes.add(dm.markUnitFailed('j', unit.unitIndex, a));
      }
      expect(outcomes, [UnitFailureOutcome.requeued, UnitFailureOutcome.requeued, UnitFailureOutcome.abandoned]);
      expect(dm.assignNext('j', a, maxUnits: 1), isEmpty);
      final p = dm.jobProgress('j');
      expect(p['failed'], 1);
      expect(p['available'], 0);
      expect(p['failure_reports'], 3);
    });

    test('a late success still completes an abandoned unit', () {
      for (var i = 0; i < 3; i++) {
        dm.markUnitFailed('j', dm.assignNext('j', a, maxUnits: 1).single.unitIndex, a);
      }
      dm.markUnitComplete('j', 0);
      expect(dm.jobProgress('j')['completed'], 1);
      expect(dm.jobProgress('j')['failed'], 0);
    });
  });

  group('ZipEntryCache', () {
    late Directory tmp;
    late Directory root;
    late File zip;
    late ZipEntryCache cache;
    final rnd = Random(7);
    List<int> bytes(int n) => List<int>.generate(n, (_) => rnd.nextInt(256));

    void writeZip(Map<String, List<int>> files, {Set<String> stored = const {}}) {
      final archive = Archive();
      archive.addFile(ArchiveFile('dir/', 0, null)..isFile = false);
      files.forEach((name, data) {
        archive.addFile(stored.contains(name)
            ? ArchiveFile.noCompress(name, data.length, Uint8List.fromList(data))
            : ArchiveFile(name, data.length, data));
      });
      zip.writeAsBytesSync(ZipEncoder().encode(archive)!);
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('zip_cache_test_');
      root = Directory(p.join(tmp.path, 'cache'));
      zip = File(p.join(tmp.path, 'data.zip'));
      cache = ZipEntryCache(() async => root);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('extracts once and serves every entry byte for byte', () async {
      final jpg = bytes(5000);
      final png = bytes(1200);
      writeZip({'a.jpg': jpg, 'dir/b.png': png}, stored: {'dir/b.png'});

      final entries = await cache.entries('id1', zip);
      expect(entries.keys, ['a.jpg', 'dir/b.png'], reason: 'archive order, directories skipped');
      expect(entries['a.jpg']!.size, jpg.length);
      expect(File(entries['a.jpg']!.path).readAsBytesSync(), jpg);
      expect(File(entries['dir/b.png']!.path).readAsBytesSync(), png);

      expect((await cache.entry('id1', zip, 'dir/b.png'))!.size, png.length);
      expect(await cache.entry('id1', zip, 'missing.jpg'), isNull);
      expect(cache.extractions, 1, reason: 'later lookups do not decode the ZIP again');
    });

    test('concurrent first requests share one extraction', () async {
      writeZip({'a.jpg': bytes(100)});
      await Future.wait([for (var i = 0; i < 5; i++) cache.entry('id1', zip, 'a.jpg')]);
      expect(cache.extractions, 1);
    });

    test('a changed file is extracted again', () async {
      writeZip({'a.jpg': bytes(100)});
      await cache.entries('id1', zip);
      final next = bytes(300);
      writeZip({'a.jpg': next});
      final e = await cache.entry('id1', zip, 'a.jpg');
      expect(cache.extractions, 2);
      expect(File(e!.path).readAsBytesSync(), next);
    });

    test('entry names cannot write outside the cache', () async {
      writeZip({'../../escape.jpg': bytes(10)});
      final e = (await cache.entries('id1', zip)).values.single;
      expect(p.isWithin(root.path, e.path), isTrue);
      expect(File(p.join(tmp.path, 'escape.jpg')).existsSync(), isFalse);
    });

    test('a corrupt ZIP fails and a later request retries', () async {
      zip.writeAsBytesSync(bytes(64));
      await expectLater(cache.entries('id1', zip), throwsA(anything));
      writeZip({'a.jpg': bytes(10)});
      expect((await cache.entries('id1', zip)).keys, ['a.jpg']);
    });

    test('leftovers from an earlier run are wiped, and clear deletes extractions', () async {
      root.createSync(recursive: true);
      File(p.join(root.path, 'stale')).writeAsStringSync('old');
      writeZip({'a.jpg': bytes(10)});
      final e = (await cache.entries('id1', zip)).values.single;
      expect(File(p.join(root.path, 'stale')).existsSync(), isFalse);
      await cache.clear();
      expect(File(e.path).existsSync(), isFalse);
    });
  });
}
