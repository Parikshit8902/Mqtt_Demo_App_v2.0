# Merged codebase notes

Base: `new_codebase.zip`
Sharing behavior selectively restored from: `old_codebase.zip`

## Decisions
- Kept the new codebase as the base so scheduler implementations, scheduler registry/model,
  host-worker participation, per-device identity handling, experiment reporting, and detailed
  metrics remain intact.
- Restored the old sharing notification contract in `services/mqtt_service.dart`:
  notifications contain `type`, `server_url`, and `target_ids`; clients retrieve the file list
  from the host's `/files` endpoint and download the listed file(s).
- Restored the old list-based `_handleFileShareMessage` implementation.
- Kept the new code's successful-download gate before ACK, QoS-aware MQTT calls, and the newer
  host-side ACK listener registration before model publication.

## Source-level conclusion
The scheduling algorithms are not on the model-sharing path. Scheduling starts later, when a
client polls for work after the dataset and warmup/reporting flow. The host-participation and
per-device identity additions likewise do not participate in MQTT model notification delivery
or HTTP model download, so they are retained from the new codebase rather than rolled back.

## Important limitation
This archive contains the source tree provided in the uploaded ZIPs. No Flutter build, analyzer,
or device runtime test was possible here, so this is a source-level integration and is not claimed
as runtime-verified.


## Follow-up fixes (2026-10-16)
- `FileServerService.shareFile` now reuses a file ID before clearing the listing, so repeated targeted dataset notifications share one stable job ID while `/files` still exposes one current file at a time.
- MQTT client IDs now encode the device name and include a per-service uniqueness token. Client tracking and metrics parsing support both new and legacy IDs. ACKs include client ID plus IP, and targeted dataset notifications accept either form.
- Reset clears stale worker/cache/ACK state. A new model notification stops the previous client worker.
- Client workers start even if warmup measurement fails; fallback estimates allow scheduler registration. Host worker is explicitly started for the dataset job and is not counted as a remote connected client.
- If no client acknowledges the model, the host still shares the dataset and attempts host-only computation instead of aborting the whole experiment.
- Static source checks only; Flutter/Dart toolchain and device runtime tests were unavailable.
