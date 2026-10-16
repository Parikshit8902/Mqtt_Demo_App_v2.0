import 'dart:math';

import 'pareto_archive.dart';

/// Maintains the bounded set of non-dominated personal-best candidates
/// for one MOMPSO particle.
///
/// Both objectives are minimized: completion time and energy consumption.
/// Dominance, duplicate handling, and crowding-distance pruning are delegated
/// to [ParetoArchive] so this policy stays consistent with the global archive.
class PersonalBestArchive {
  final ParetoArchive _archive;

  /// Creates a personal-best archive.
  ///
  /// MOMPSO currently uses a capacity of `min(5, archiveSize)`.
  PersonalBestArchive({int capacity = 5})
      : assert(capacity > 0),
        _archive = ParetoArchive(capacity: capacity);

  /// Number of retained candidates.
  int get length => _archive.length;

  /// Whether the archive contains no candidates.
  bool get isEmpty => _archive.isEmpty;

  /// Read-only view of retained candidates.
  List<ParetoSolution> get solutions => _archive.solutions;

  /// Offers [candidate] to the personal-best set.
  ///
  /// Returns true if the archive changes. Dominated candidates and duplicate
  /// assignments are rejected by [ParetoArchive].
  bool add(ParetoSolution candidate) => _archive.add(candidate);

  /// Selects a cognitive target from the retained personal-best set.
  ///
  /// A seeded [random] makes selection reproducible for the same archive state
  /// and sequence of calls. Throws [StateError] if the archive is empty.
  ParetoSolution selectLeader(Random random) => _archive.selectLeader(random);

  /// Returns crowding distances aligned with [solutions].
  List<double> crowdingDistances() => _archive.crowdingDistances();
}