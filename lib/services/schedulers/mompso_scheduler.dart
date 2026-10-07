import '../models/assignment.dart';
import 'dynamic_scheduler.dart';
import 'scheduling_model.dart';

/// Multi-objective scheduler (DetectNet's `schedMOMPSO`): every phone gets one
/// weighted score and the unit goes to the phone with the highest.
///
///   score = w.health * health - w.latency * latency - w.queue * queue - w.energy * energy
///
/// Each term is computed by [FleetModel.objective] from live device state, so
/// this class only decides which weights to use and takes the argmax. Units are
/// handed out one at a time and every assignment lengthens the winner's queue,
/// which is what moves the next unit to a different phone once the best one is
/// busy.
///
/// Two weight sets are provided, switch by passing `weights`:
///  * [ObjectiveWeights.dynamicMompso] (default): the original weights scaled by
///    0.8 with the remaining 0.2 on energy (health 0.40, latency 0.24,
///    queue 0.16, energy 0.20). The energy term is what separates two
///    otherwise equal phones, so a phone on a charger or a lower-power SoC wins.
///  * [ObjectiveWeights.detectnetMompso]: DetectNet's original three terms with
///    no energy (health 0.50, latency 0.30, queue 0.20), for comparing against
///    the web app.
///
/// Deterministic: ties are broken by client id, so [random] is accepted only to
/// keep the constructor uniform across the four schedulers.
class MOMPSOScheduler extends DynamicScheduler {
  final ObjectiveWeights weights;

  MOMPSOScheduler({
    super.random,
    super.config,
    this.weights = ObjectiveWeights.dynamicMompso,
  });

  @override
  String get id => 'mompso';

  @override
  String get label => 'MOMPSO';

  @override
  String pick(FleetModel fleet, List<String> open, Unit unit) {
    return DynamicScheduler.argmax(
      open,
      (clientId) => fleet.objective(clientId, weights),
    );
  }
}
