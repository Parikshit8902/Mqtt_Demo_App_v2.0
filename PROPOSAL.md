# Proposal: measurement, scheduling and robustness roadmap

Status of the five goals, then what else is worth doing. Every item below is
grounded in something found in the code; file references are included.

## 1. Where the five goals stand

| Goal | Status |
|---|---|
| Metrics for every phone, separately | Done. Each phone records 2 s samples + per-unit records; the host collects all phones (live over MQTT every 5 s, full detail when a worker uploads its report). Per-phone chips, charts and summary in **Analytics → chart icon**; export as CSV/JSON in-app or from `http://<host>:8080/admin/metrics.csv`. |
| Other distribution algorithms (PSO...) | Plug-in point done (`SchedulerRegistry`), with greedy, round-robin and random baselines. PSO and the professor's algorithm are one class + one registry line each. |
| Network, CPU, power | CPU (raw and per-SoC), memory, on-wire network, battery power (measured, Android) and modelled app power/energy are recorded. See "Limits" below. |
| Network overhead and data volume | Done. Payload is counted per channel (images/models, control, MQTT, metrics reporting) and compared with on-wire bytes; the difference is the overhead. |
| Fix bandwidth measurement | Done. Link speed is now bytes / **download** time (it was derived from inference time). |

### Limits to keep in mind when reading results
* **Power is an estimate.** Android phones expose whole-device battery current x voltage (recorded as "measured"), not per-app power. App power is modelled from CPU and Wi-Fi activity with uncalibrated constants (`power_model.dart`). Calibrate per phone model against the measured series, or use a hardware monitor for the paper.
* **GPU/NPU inference is invisible to CPU time**, so the model under-reports energy when `useGpu` is on.
* **iOS is partial.** CPU, memory and battery % work; network counters are for the whole Wi-Fi interface (iOS has no per-app counters); there is no disk metric and no battery current, so measured power is unavailable.
* **Host overhead includes MQTT relay.** The broker phone's on-wire bytes include traffic it forwards for others, which shows as "unattributed".
* The metrics timer stops when the app is backgrounded (see 2.5), leaving gaps.

## 2. Recommended next steps (highest value first)

1. **Fault tolerance for work units.** *Done: 60 s leases, worker failure reports with immediate requeue, and a 3-attempt limit per unit.* `DistributionManager` marks a unit `assigned` and never takes it back. If a phone crashes, loses Wi-Fi or its download fails, that unit is stuck and the job never finishes. Add a lease (timeout and re-queue), and have the worker report failures instead of dropping them. Related: when inference throws, the worker still posts a result and the unit is counted complete with no detections (`client_worker_service.dart`), which silently corrupts both accuracy and timing.
2. **Stop re-decoding the ZIP on every request.** *Done: `ZipEntryCache` extracts each ZIP once, in a background isolate, and entries are served from disk.* The host reads and decodes the whole dataset ZIP for each `?entry=` request (`file_server_service.dart`, `_handleFileDownloadRequest`), and again when building the job. That is slow, memory-hungry, and inflates both host CPU and every worker's measured download time. Extract once (or index entry offsets) and cache.
3. **Experiment harness.** A run config (scheduler, units, seed, phones) with automatic repeats, a fixed output folder, and run metadata in the export (device models, OS, app version, Wi-Fi band/RSSI). Then a comparison view: makespan, throughput (units/s), per-unit latency percentiles, load imbalance (Jain's fairness index), energy per unit. Without this, scheduler comparisons are hard to reproduce.
4. **Clock alignment between phones.** Timelines from different phones can only be overlaid if clocks agree. Estimate each phone's offset to the host during warm-up (NTP-style over the existing HTTP calls) and store it with the samples.
5. **Run reliably in the background.** *Partly done: while a phone hosts or works, the screen is kept on and leaving the foreground no longer stops sampling (the `inactive` state never does). On Android a foreground service with CPU and Wi-Fi locks covers the screen-off case (builds; not yet tested on a device).* `PerformanceService` stops its timer when the app is paused (`didChangeAppLifecycleState`), and Android may also suspend the worker. For long experiments use a foreground service and a wake lock, or keep the screen on during runs.
6. **Context that explains the numbers.** Wi-Fi RSSI/link speed/band, thermal status (Android `PowerManager` thermal API, iOS `ProcessInfo.thermalState`), charging state. Sustained inference on phones throttles; without thermal data a slow run looks like a scheduler problem.
7. **Cut idle polling.** *Done: idle polls back off from 2 s to 16 s, and the host announces new work on the `work/available` MQTT topic.* An idle worker calls `/assignments/.../next` every 2 s forever. That is steady control traffic and radio wake-ups. Use exponential backoff, or have the host push "work available" over MQTT.

## 3. Scheduling improvements (for when the algorithms arrive)

* **Pull vs. plan.** Today every request recomputes a schedule for all phones and keeps one phone's share. Global optimisers (PSO and similar) should compute a plan once, cache it, and serve shares from it, recomputing on events (phone joins/leaves, estimate drifts). The `Scheduler` docs describe this. Scheduling cost is now measured (`avgScheduleMs`), which matters because a PSO run on a phone host is far heavier than greedy.
* **Better estimates.** Today a phone is described by two numbers (inference ms, link kB/s) updated by an EMA (alpha 0.2). Candidates: separate per-phone download and compute queues, variance/confidence, battery- and thermal-aware speed, and an energy term for energy-aware objectives (the data is now there).
* **Adaptive batch size.** `maxUnits` is fixed at 2 per request. Larger batches amortise control traffic; smaller ones balance load near the end of a job.
* **Churn.** Handle phones joining or leaving mid-job (ties into 2.1).

## 4. Network/data-volume ideas
* Down-scale or re-encode images on the host before sending (JPEG quality, resolution) and measure the accuracy/bandwidth/energy trade-off; often the largest lever in this kind of system.
* Compress or trim result payloads (detections JSON).
* Co-locate work with data: skip transfer for units a phone already holds.

## 5. Housekeeping
* **Security:** *Done: a per-session 6-digit PIN guards the broker (MQTT login) and `/admin/*`, `/assignments/*` and the file list (HTTP).* The MQTT broker had no authentication and the `/admin/*` HTTP endpoints (including the new scheduler/metrics ones) are open to anyone on the Wi-Fi. Fine for a lab network; add a shared token before anything wider.
* **Tests/CI:** *Done: `test/widget_test.dart` is a real smoke test and `.github/workflows/ci.yml` runs `flutter analyze --no-fatal-infos` and `flutter test`.* `test/widget_test.dart` was the stale Flutter counter template and failed. New unit tests live in `test/metrics_and_scheduler_test.dart`. A CI job running `flutter analyze` and `flutter test` would catch regressions.
* **Job model:** the code still special-cases `demo_job` and uses the shared file id as the job id; a real job object (id, dataset, model, scheduler, status) would simplify the UI and the harness.
* The MQTT client previously handled only the first message of each delivery batch (now fixed); worth a regression test with a live broker.
