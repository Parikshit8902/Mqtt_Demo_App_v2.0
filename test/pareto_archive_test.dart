
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/schedulers/pareto_archive.dart';

ParetoSolution solution(
  List<int> assignment, {
  required double time,
  required double energy,
}) {
  return ParetoSolution(
    assignments: assignment,
    objectives: ParetoObjectives(
      completionTime: time,
      energy: energy,
    ),
  );
}

void main() {
  group('Pareto dominance', () {
    test('strictly better in both objectives dominates', () {
      final a = ParetoObjectives(completionTime: 100, energy: 20);
      final b = ParetoObjectives(completionTime: 120, energy: 25);

      expect(ParetoArchive.dominates(a, b), isTrue);
      expect(ParetoArchive.dominates(b, a), isFalse);
    });

    test('faster but more energy-intensive solution does not dominate', () {
      final a = ParetoObjectives(completionTime: 100, energy: 30);
      final b = ParetoObjectives(completionTime: 120, energy: 20);

      expect(ParetoArchive.dominates(a, b), isFalse);
      expect(ParetoArchive.dominates(b, a), isFalse);
    });

    test('equal time and lower energy dominates', () {
      final a = ParetoObjectives(completionTime: 100, energy: 20);
      final b = ParetoObjectives(completionTime: 100, energy: 25);

      expect(ParetoArchive.dominates(a, b), isTrue);
      expect(ParetoArchive.dominates(b, a), isFalse);
    });

    test('identical objective values do not strictly dominate', () {
      final a = ParetoObjectives(completionTime: 100, energy: 20);
      final b = ParetoObjectives(completionTime: 100, energy: 20);

      expect(ParetoArchive.dominates(a, b), isFalse);
      expect(ParetoArchive.dominates(b, a), isFalse);
    });

    test('lower time but equal energy dominates', () {
      final a = ParetoObjectives(completionTime: 90, energy: 20);
      final b = ParetoObjectives(completionTime: 100, energy: 20);

      expect(ParetoArchive.dominates(a, b), isTrue);
    });
  });

  group('Pareto archive', () {
    test('preserves non-dominated trade-offs', () {
      final archive = ParetoArchive();

      expect(
        archive.add(solution([0], time: 100, energy: 30)),
        isTrue,
      );
      expect(
        archive.add(solution([1], time: 120, energy: 20)),
        isTrue,
      );

      expect(archive.length, 2);
    });

    test('rejects a dominated candidate', () {
      final archive = ParetoArchive();

      archive.add(solution([0], time: 100, energy: 20));

      expect(
        archive.add(solution([1], time: 120, energy: 25)),
        isFalse,
      );

      expect(archive.length, 1);
      expect(archive.solutions.single.assignments, [0]);
    });

    test('removes existing solutions dominated by a new candidate', () {
      final archive = ParetoArchive();

      archive.add(solution([0], time: 120, energy: 25));
      archive.add(solution([1], time: 110, energy: 22));

      expect(
        archive.add(solution([2], time: 90, energy: 15)),
        isTrue,
      );

      expect(archive.length, 1);
      expect(archive.solutions.single.assignments, [2]);
    });

    test('does not store duplicate assignments', () {
      final archive = ParetoArchive();

      expect(
        archive.add(solution([0, 1], time: 100, energy: 20)),
        isTrue,
      );

      // Same assignment is rejected even if re-evaluated with different
      // objective values.
      expect(
        archive.add(solution([0, 1], time: 90, energy: 15)),
        isFalse,
      );

      expect(archive.length, 1);
    });

    test('crowding distances preserve boundary solutions', () {
      final archive = ParetoArchive();

      archive.add(solution([0], time: 100, energy: 40));
      archive.add(solution([1], time: 110, energy: 30));
      archive.add(solution([2], time: 120, energy: 20));
      archive.add(solution([3], time: 130, energy: 10));

      final distances = archive.crowdingDistances();

      expect(distances.length, 4);
      expect(distances.any((d) => d == double.infinity), isTrue);
      expect(distances.every((d) => d >= 0), isTrue);
    });

    test('archive remains bounded', () {
      final archive = ParetoArchive(capacity: 3);

      // Each candidate trades time against energy, so none dominates another.
      for (var i = 0; i < 8; i++) {
        archive.add(
          solution(
            [i],
            time: 100.0 + i,
            energy: 30.0 - i,
          ),
        );
      }

      expect(archive.length, lessThanOrEqualTo(3));
    });

    test('seeded leader selection is reproducible', () {
      ParetoArchive createArchive() {
        final archive = ParetoArchive();

        archive.add(solution([0], time: 100, energy: 30));
        archive.add(solution([1], time: 120, energy: 20));
        archive.add(solution([2], time: 140, energy: 10));

        return archive;
      }

      List<List<int>> run(int seed) {
        final archive = createArchive();
        final random = Random(seed);

        return List.generate(
          20,
          (_) => archive.selectLeader(random).assignments,
        );
      }

      expect(run(42), equals(run(42)));
    });
  });
}