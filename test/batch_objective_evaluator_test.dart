import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/models/assignment.dart';
import 'package:mqtt_demo/services/models/device_health.dart';
import 'package:mqtt_demo/services/models/result_dto.dart';
import 'package:mqtt_demo/services/schedulers/batch_objective_evaluator.dart';
import 'package:mqtt_demo/services/schedulers/scheduling_model.dart';

Unit _unit(int index, int bytes) => Unit(
      unitIndex: index,
      start: 0,
      end: bytes - 1,
      fileUrl: 'http://host/$index',
    );

ClientEstimate _client({
  double procMs = 200,
  double bandwidthKbps = 1000,
  int pending = 0,
  int batteryPct = 80,
}) =>
    ClientEstimate(
      ttprocMs: procMs,
      bandwidthKbps: bandwidthKbps,
      pending: pending,
      health: DeviceHealth(
        batteryPct: batteryPct,
        charging: false,
        cpuPct: 20,
      ),
    );

void main() {
  group('BatchObjectiveEvaluator', () {
    final units = [_unit(0, 512 * 1024), _unit(1, 1024 * 1024)];

    test('same complete assignment has stable makespan and energy', () {
      final fleet = FleetModel(
        {
          'a': _client(procMs: 200, bandwidthKbps: 1000),
          'b': _client(procMs: 300, bandwidthKbps: 2000),
        },
        units,
        4,
      );
      const clientIds = ['a', 'b'];
      const capacities = [1, 1];
      const assignment = [0, 1];

      final first = BatchObjectiveEvaluator.evaluate(
        fleet: fleet,
        units: units,
        clientIds: clientIds,
        capacities: capacities,
        assignment: assignment,
      );
      final second = BatchObjectiveEvaluator.evaluate(
        fleet: fleet,
        units: units,
        clientIds: clientIds,
        capacities: capacities,
        assignment: assignment,
      );

      expect(first.completionTime, closeTo(second.completionTime, 1e-9));
      expect(first.energy, closeTo(second.energy, 1e-9));
      expect(first.completionTime, greaterThan(0));
      expect(first.energy, greaterThan(0));
    });

    test('charges radio startup and tail overhead only once per idle worker batch', () {
      final fleet = FleetModel(
        {'a': _client(procMs: 200, bandwidthKbps: 1000)},
        units,
        4,
      );

      final objective = BatchObjectiveEvaluator.evaluate(
        fleet: fleet,
        units: units,
        clientIds: const ['a'],
        capacities: const [2],
        assignment: const [0, 0],
      );

      final view = fleet.views['a']!;
      final firstTaskEnergy = EnergyEstimator.unitEnergyJ(
        power: view.power,
        procMs: view.procMs,
        cpuUtil: 0.7,
        radioWarm: false,
      );
      final subsequentTaskEnergy = EnergyEstimator.unitEnergyJ(
        power: view.power,
        procMs: view.procMs,
        cpuUtil: 0.7,
        radioWarm: true,
      );

      expect(
        objective.energy,
        closeTo(firstTaskEnergy + subsequentTaskEnergy, 1e-9),
      );
    });

    test('rejects assignment vector with wrong length', () {
      final fleet = FleetModel({'a': _client()}, units, 4);

      expect(
        () => BatchObjectiveEvaluator.evaluate(
          fleet: fleet,
          units: units,
          clientIds: const ['a'],
          capacities: const [2],
          assignment: const [0],
        ),
        throwsArgumentError,
      );
    });

    test('rejects invalid worker index', () {
      final fleet = FleetModel({'a': _client()}, units, 4);

      expect(
        () => BatchObjectiveEvaluator.evaluate(
          fleet: fleet,
          units: units,
          clientIds: const ['a'],
          capacities: const [2],
          assignment: const [0, 1],
        ),
        throwsArgumentError,
      );
    });

    test('rejects assignments exceeding remaining capacity', () {
      final fleet = FleetModel({'a': _client()}, units, 4);

      expect(
        () => BatchObjectiveEvaluator.evaluate(
          fleet: fleet,
          units: units,
          clientIds: const ['a'],
          capacities: const [1],
          assignment: const [0, 0],
        ),
        throwsArgumentError,
      );
    });

    test('rejects a worker excluded by health eligibility', () {
      final fleet = FleetModel(
        {
          'healthy': _client(),
          'gated': _client(batteryPct: 1),
        },
        units,
        4,
      );

      expect(
        () => BatchObjectiveEvaluator.evaluate(
          fleet: fleet,
          units: units,
          clientIds: const ['healthy', 'gated'],
          capacities: const [2, 2],
          assignment: const [0, 1],
        ),
        throwsArgumentError,
      );
    });
  });
}