import '../models/assignment.dart';
import 'dynamic_scheduler.dart';
import 'scheduling_model.dart';

/// MOMPSO-GA: DetectNet's `schedGA`, scored from live device state.
///
/// A heuristic with a genetic flavour, not a search. Each open phone is scored
/// with the same weighted objective MOMPSO uses (health, latency, queue depth
/// and energy, all from live data) plus a small random mutation. The two best
/// mutated scores are crossed over as a 70/30 blend, and the phone whose mutated
/// score is closest to that blend wins.
///
/// Be aware that with [eliteShare] above 0.5 the blend always lies nearer the
/// top mutated score than any other, so the winner is the top mutated score;
/// the mutation is what lets near-equal phones trade places. The blend is kept
/// because it is the reference algorithm (below 0.5 it would pick the runner-up).
///
/// [ObjectiveWeights.detectnetGa] is the original three-term weighting; the
/// default [ObjectiveWeights.dynamicGa] makes room for the energy term.
class MOMPSOGAScheduler extends DynamicScheduler {
  /// Weights of the objective each phone is scored with, before mutation.
  final ObjectiveWeights weights;

  /// Mutation is uniform and symmetric in [-mutation, +mutation].
  final double mutation;

  /// Share of the blend taken from the best score; the rest from the second.
  final double eliteShare;

  MOMPSOGAScheduler({
    super.random,
    super.config,
    this.weights = ObjectiveWeights.dynamicGa,
    this.mutation = 0.04,
    this.eliteShare = 0.7,
  })  : assert(mutation >= 0),
        assert(eliteShare >= 0 && eliteShare <= 1);

  @override
  String get id => 'mompso-ga';

  @override
  String get label => 'MOMPSO-GA';

  @override
  String pick(FleetModel fleet, List<String> open, Unit unit) {
    // Sorted so a seeded random stream lands on the same phones whatever the
    // map order of the clients was.
    final ids = List<String>.from(open)..sort();

    final scores = <String, double>{};
    for (final id in ids) {
      final noise = (random.nextDouble() * 2 - 1) * mutation;
      scores[id] = fleet.objective(id, weights) + noise;
    }

    // Crossover: blend the two best mutated scores (a lone phone is its own blend).
    final ranked = List<String>.from(ids)
      ..sort((a, b) {
        final byScore = scores[b]!.compareTo(scores[a]!);
        return byScore != 0 ? byScore : a.compareTo(b);
      });
    final best = scores[ranked.first]!;
    final blended = ranked.length > 1 ? eliteShare * best + (1 - eliteShare) * scores[ranked[1]]! : best;

    return DynamicScheduler.argmax(ids, (id) => -(scores[id]! - blended).abs());
  }
}
