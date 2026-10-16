import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_demo/services/schedulers/scheduling_model.dart';

void main() {
  group('EnergyEstimator.unitEnergyJ', () {
    const power = DevicePower(1.4, 4.6, 15.0);

    test('charges compute, transfer, ramp, and tail for a cold radio', () {
      final energy = EnergyEstimator.unitEnergyJ(
        power: power,
        procMs: 1000,
        cpuUtil: 0.7,
        radioWarm: false,
      );

      // Estimated power: 1.4 + (4.6 - 1.4) * 0.7 = 3.64 W.
      // Compute: 3.64 J; transfers: 0.004 J; ramp + tail: 0.020 J.
      expect(energy, closeTo(3.664, 1e-12));
    });

    test('omits ramp and tail when the radio session is already active', () {
      final energy = EnergyEstimator.unitEnergyJ(
        power: power,
        procMs: 1000,
        cpuUtil: 0.7,
        radioWarm: true,
      );

      // Compute: 3.64 J; transfers: 0.004 J; no ramp/tail overhead.
      expect(energy, closeTo(3.644, 1e-12));
    });

    test('cold-radio overhead is exactly ramp plus tail', () {
      final cold = EnergyEstimator.unitEnergyJ(
        power: power,
        procMs: 500,
        cpuUtil: 0.5,
        radioWarm: false,
      );
      final warm = EnergyEstimator.unitEnergyJ(
        power: power,
        procMs: 500,
        cpuUtil: 0.5,
        radioWarm: true,
      );

      expect(cold - warm, closeTo(
        EnergyEstimator.wifiRampJ + EnergyEstimator.wifiTailJ,
        1e-12,
      ));
    });

    test('clamps CPU utilization below zero to idle power', () {
      final negativeUtilization = EnergyEstimator.unitEnergyJ(
        power: power,
        procMs: 1000,
        cpuUtil: -0.5,
        radioWarm: true,
      );
      final zeroUtilization = EnergyEstimator.unitEnergyJ(
        power: power,
        procMs: 1000,
        cpuUtil: 0,
        radioWarm: true,
      );

      expect(negativeUtilization, closeTo(zeroUtilization, 1e-12));
      expect(negativeUtilization, closeTo(1.404, 1e-12));
    });

    test('clamps CPU utilization above one to maximum power', () {
      final excessiveUtilization = EnergyEstimator.unitEnergyJ(
        power: power,
        procMs: 1000,
        cpuUtil: 1.5,
        radioWarm: true,
      );
      final fullUtilization = EnergyEstimator.unitEnergyJ(
        power: power,
        procMs: 1000,
        cpuUtil: 1,
        radioWarm: true,
      );

      expect(excessiveUtilization, closeTo(fullUtilization, 1e-12));
      expect(excessiveUtilization, closeTo(4.604, 1e-12));
    });

    test('compute energy scales linearly with processing duration', () {
      final shortTask = EnergyEstimator.unitEnergyJ(
        power: power,
        procMs: 500,
        cpuUtil: 0.7,
        radioWarm: true,
      );
      final longTask = EnergyEstimator.unitEnergyJ(
        power: power,
        procMs: 1000,
        cpuUtil: 0.7,
        radioWarm: true,
      );

      // Network energy is fixed by this model; doubling processing time adds
      // exactly one more 500 ms of compute energy (3.64 W * 0.5 s = 1.82 J).
      expect(longTask - shortTask, closeTo(1.82, 1e-12));
    });
  });
}