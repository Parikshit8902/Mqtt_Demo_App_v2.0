import 'dart:math';

/// Two objectives to minimize.
class ParetoObjectives {
  final double completionTime;
  final double energy;

  const ParetoObjectives({required this.completionTime, required this.energy})
    : assert(completionTime >= 0),
      assert(energy >= 0);
}

/// A candidate assignment and its objective values.
class ParetoSolution {
  final List<int> assignments;
  final ParetoObjectives objectives;

  ParetoSolution({required List<int> assignments, required this.objectives})
    : assignments = List<int>.unmodifiable(assignments);
}

/// Maintains a bounded Pareto archive.
///
/// Both objectives are minimized. The archive:
/// - rejects duplicate assignments;
/// - rejects candidates dominated by an archive member;
/// - removes archive members dominated by a candidate;
/// - limits its size using crowding-distance pruning.
class ParetoArchive {
  final int capacity;
  final List<ParetoSolution> _solutions = [];

  ParetoArchive({this.capacity = 30}) : assert(capacity > 0);

  List<ParetoSolution> get solutions =>
      List<ParetoSolution>.unmodifiable(_solutions);

  int get length => _solutions.length;

  bool get isEmpty => _solutions.isEmpty;

  /// Returns true if [a] Pareto-dominates [b].
  ///
  /// A must be no worse in either objective and strictly better in at
  /// least one objective.
  static bool dominates(ParetoObjectives a, ParetoObjectives b) {
    final noWorse =
        a.completionTime <= b.completionTime && a.energy <= b.energy;

    final strictlyBetter =
        a.completionTime < b.completionTime || a.energy < b.energy;

    return noWorse && strictlyBetter;
  }

  /// Adds a candidate if it contributes a new non-dominated assignment.
  ///
  /// Returns true if the archive changed.
  bool add(ParetoSolution candidate) {
    if (_solutions.any(
      (existing) =>
          _sameAssignment(existing.assignments, candidate.assignments),
    )) {
      return false;
    }

    if (_solutions.any(
      (existing) => dominates(existing.objectives, candidate.objectives),
    )) {
      return false;
    }

    _solutions.removeWhere(
      (existing) => dominates(candidate.objectives, existing.objectives),
    );

    _solutions.add(candidate);

    if (_solutions.length > capacity) {
      _pruneMostCrowded();
    }

    return true;
  }

  /// Selects an archive leader from a region with high crowding distance.
  ///
  /// Randomness is injected so callers can use a seeded Random.
  ParetoSolution selectLeader(Random random) {
    if (_solutions.isEmpty) {
      throw StateError('Cannot select a leader from an empty Pareto archive.');
    }

    if (_solutions.length == 1) return _solutions.first;

    final distances = _crowdingDistances();

    final maxDistance = distances.reduce(max);
    final candidates = <int>[
      for (var i = 0; i < distances.length; i++)
        if (distances[i] == maxDistance) i,
    ];

    return _solutions[candidates[random.nextInt(candidates.length)]];
  }

  /// Returns crowding distances aligned with [solutions].
  ///
  /// Boundary solutions receive infinite distance to preserve the ends
  /// of the Pareto front.
  List<double> crowdingDistances() => _crowdingDistances();

  void _pruneMostCrowded() {
    final distances = _crowdingDistances();

    var removeIndex = 0;

    for (var i = 1; i < _solutions.length; i++) {
      if (distances[i] < distances[removeIndex]) {
        removeIndex = i;
      } else if (distances[i] == distances[removeIndex] &&
          _lexicographicallyGreater(
            _solutions[i].assignments,
            _solutions[removeIndex].assignments,
          )) {
        removeIndex = i;
      }
    }

    _solutions.removeAt(removeIndex);
  }

  List<double> _crowdingDistances() {
    final distances = List<double>.filled(_solutions.length, 0.0);

    if (_solutions.length <= 2) {
      return List<double>.filled(_solutions.length, double.infinity);
    }

    void processObjective(double Function(ParetoSolution) value) {
      final indices = List<int>.generate(_solutions.length, (i) => i)
        ..sort((a, b) {
          final comparison = value(
            _solutions[a],
          ).compareTo(value(_solutions[b]));
          return comparison != 0 ? comparison : a.compareTo(b);
        });

      final minimum = value(_solutions[indices.first]);
      final maximum = value(_solutions[indices.last]);
      final range = maximum - minimum;

      distances[indices.first] = double.infinity;
      distances[indices.last] = double.infinity;

      if (range == 0) return;

      for (var i = 1; i < indices.length - 1; i++) {
        final index = indices[i];

        if (distances[index] == double.infinity) continue;

        final previous = value(_solutions[indices[i - 1]]);
        final next = value(_solutions[indices[i + 1]]);

        distances[index] += (next - previous) / range;
      }
    }

    processObjective((s) => s.objectives.completionTime);
    processObjective((s) => s.objectives.energy);

    return distances;
  }

  static bool _sameAssignment(List<int> a, List<int> b) {
    if (a.length != b.length) return false;

    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }

    return true;
  }

  static bool _lexicographicallyGreater(List<int> a, List<int> b) {
    final length = min(a.length, b.length);

    for (var i = 0; i < length; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }

    return a.length > b.length;
  }
}
