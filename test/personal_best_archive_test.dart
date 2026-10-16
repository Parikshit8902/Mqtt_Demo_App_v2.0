import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/schedulers/personal_best_archive.dart';
import 'package:mqtt_demo/services/schedulers/pareto_archive.dart';

/// Creates a solution with the specified assignment and objectives.
ParetoSolution solution(
  List<int> assignments, {
  required double completionTime,
  required double energy,
}) {
  return ParetoSolution(
    assignments: assignments,
    objectives: ParetoObjectives(
      completionTime: completionTime,
      energy: energy,
    ),
  );
}

void main() {
  group('PersonalBestArchive', () {
    test('retains non-dominated solutions with different trade-offs', () {
      final archive = PersonalBestArchive(capacity: 5);

      final faster = solution(
        [0, 0, 1],
        completionTime: 10,
        energy: 100,
      );

      final moreEfficient = solution(
        [0, 1, 1],
        completionTime: 12,
        energy: 80,
      );

      expect(archive.add(faster), isTrue);
      expect(archive.add(moreEfficient), isTrue);

      expect(archive.length, 2);
      expect(archive.solutions, contains(faster));
      expect(archive.solutions, contains(moreEfficient));
    });

    test('rejects a candidate dominated by an existing solution', () {
      final archive = PersonalBestArchive(capacity: 5);

      final existing = solution(
        [0, 0, 1],
        completionTime: 10,
        energy: 80,
      );

      final dominated = solution(
        [0, 1, 1],
        completionTime: 12,
        energy: 100,
      );

      archive.add(existing);

      expect(archive.add(dominated), isFalse);
      expect(archive.length, 1);
      expect(archive.solutions, contains(existing));
      expect(archive.solutions, isNot(contains(dominated)));
    });

    test('removes existing solutions dominated by a new candidate', () {
      final archive = PersonalBestArchive(capacity: 5);

      final slower = solution(
        [0, 0, 1],
        completionTime: 12,
        energy: 100,
      );

      final lessEfficient = solution(
        [0, 1, 1],
        completionTime: 10,
        energy: 120,
      );

      final best = solution(
        [1, 1, 0],
        completionTime: 8,
        energy: 70,
      );

      archive.add(slower);
      archive.add(lessEfficient);

      expect(archive.add(best), isTrue);
      expect(archive.length, 1);
      expect(archive.solutions, contains(best));
      expect(archive.solutions, isNot(contains(slower)));
      expect(archive.solutions, isNot(contains(lessEfficient)));
    });

    test('does not retain a duplicate assignment', () {
      final archive = PersonalBestArchive(capacity: 5);

      final original = solution(
        [0, 1, 0],
        completionTime: 10,
        energy: 80,
      );

      final duplicateAssignment = solution(
        [0, 1, 0],
        completionTime: 9,
        energy: 70,
      );

      expect(archive.add(original), isTrue);
      expect(archive.add(duplicateAssignment), isFalse);
      expect(archive.length, 1);
    });

    test('does not exceed its configured capacity', () {
      const capacity = 2;
      final archive = PersonalBestArchive(capacity: capacity);

      // Each candidate improves completion time while increasing energy.
      // These candidates are mutually non-dominated.
      final candidates = <ParetoSolution>[
        solution([0, 0, 0], completionTime: 10, energy: 100),
        solution([0, 0, 1], completionTime: 9, energy: 110),
        solution([0, 1, 1], completionTime: 8, energy: 120),
        solution([1, 1, 1], completionTime: 7, energy: 130),
      ];

      for (final candidate in candidates) {
        archive.add(candidate);
        expect(
          archive.length,
          lessThanOrEqualTo(capacity),
          reason: 'Archive exceeded its configured capacity.',
        );
      }

      expect(archive.length, capacity);
    });

    test('selects a leader that belongs to the archive', () {
      final archive = PersonalBestArchive(capacity: 5);

      archive.add(
        solution([0, 0, 1], completionTime: 10, energy: 100),
      );
      archive.add(
        solution([0, 1, 1], completionTime: 12, energy: 80),
      );

      final leader = archive.selectLeader(Random(42));

      expect(archive.solutions, contains(leader));
    });

    test('returns reproducible leader selections for the same seed', () {
      PersonalBestArchive createArchive() {
        final archive = PersonalBestArchive(capacity: 5);

        archive.add(
          solution([0, 0, 1], completionTime: 10, energy: 100),
        );
        archive.add(
          solution([0, 1, 1], completionTime: 12, energy: 80),
        );
        archive.add(
          solution([1, 1, 0], completionTime: 8, energy: 120),
        );

        return archive;
      }

      final firstArchive = createArchive();
      final secondArchive = createArchive();

      final firstRandom = Random(123);
      final secondRandom = Random(123);

      for (var i = 0; i < 20; i++) {
        final firstLeader = firstArchive.selectLeader(firstRandom);
        final secondLeader = secondArchive.selectLeader(secondRandom);

        expect(
          firstLeader.assignments,
          equals(secondLeader.assignments),
        );
        expect(
          firstLeader.objectives.completionTime,
          equals(secondLeader.objectives.completionTime),
        );
        expect(
          firstLeader.objectives.energy,
          equals(secondLeader.objectives.energy),
        );
      }
    });

    test('reports its empty state correctly', () {
      final archive = PersonalBestArchive(capacity: 5);

      expect(archive.isEmpty, isTrue);
      expect(archive.length, 0);

      archive.add(
        solution([0, 1], completionTime: 10, energy: 80),
      );

      expect(archive.isEmpty, isFalse);
      expect(archive.length, 1);
    });
  });
}