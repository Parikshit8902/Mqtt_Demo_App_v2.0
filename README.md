# MQTT Demo App — Simple Guide

Welcome — this app helps devices on the same Wi‑Fi network send short messages and share files with each other.

You don't need to be technical to use it. Below is a simple explanation of what it does and how to try it.

## What this app can do (simple)
- Turn your phone or computer into a small message server (so other devices can connect to it).
- Let a device connect to that server and send or receive short text messages.
- Share files from one device to others using a built-in simple file page (no big uploads through chat).
- Find available servers on your local Wi‑Fi automatically or let you enter the server address by hand.

## Two main modes explained in plain words
- Broker mode ("Be the server"): Your device becomes the central point that accepts connections and forwards messages to connected devices.
- Client mode ("Join a server"): Your device connects to a broker (server) and can send or receive messages and file notifications.

These two modes let you test sending and receiving messages between multiple devices on the same Wi‑Fi.

## Try it — step by step (non-technical)
1. Install and open the app on two devices on the same Wi‑Fi network (for example, two phones).
2. On Device A (the one that will act as server):
  - Tap "Become MQTT Broker" and then "Start Broker". The app will show an IP address — note this down or share it.
3. On Device B (a client):
  - Tap "Become MQTT Client".
  - Use the automatic search (magnifier icon) to find the broker shown by Device A, or type that IP address into the broker field.
  - Tap "Connect" and then tap "Subscribe" to start receiving messages.
4. On Device B, tap "Publish Message" to send a test message — both devices should show the message in the log.

Tip: You can repeat the client steps for Device C, Device D, etc., so many devices can chat through the broker.

## Sharing files (simple overview)
- The app can start a small, temporary file page on the device that is acting as the broker.
- The broker shares the file's address (a simple web link) via a short message. Other devices use that link to download the file directly.
- This approach keeps files off the message system and uses a regular download so things stay fast and simple.

## Model management screen (for ML demos)
- The app also includes a screen that can download a small machine learning model and a sample dataset and run local tests (this is optional).
- This screen is mainly for testing and learning how models perform on the device; you can also export detection results if you try it.

## Metrics, export and scheduling (for experiments)
- Open **Analytics → chart icon** to see per-phone CPU, memory, network, power, battery and per-image timings, plus how much data was real payload versus protocol overhead.
- **Export** writes `summary.csv`, `samples.csv`, `units.csv` and `full.json`. On the broker phone it covers every phone; on a worker it covers that phone. Android: `Android/data/com.example.mqtt_demo/files/metrics_exports`; iOS: the app's folder in the Files app.
- Workers send their full recording to the broker phone automatically when their work runs dry (or press **Send report to host**).
- From a laptop on the same Wi-Fi: `http://<broker-ip>:8080/admin/metrics.csv?kind=summary|samples|units` (optionally `&device=<phone-ip>`), or `/admin/metrics.json` for JSON (`/admin/metrics` is the plain-text experiment report with its Download button).
- Pick the scheduling algorithm in the metrics screen (broker phone), or `curl -X POST http://<broker-ip>:8080/admin/scheduler -d '{"id":"round_robin"}'`. New algorithms are registered in `lib/services/schedulers/scheduler_registry.dart`.
- Power is an estimate; see `PROPOSAL.md` for what is measured, what is modelled, and the iOS limits.

## Dynamic scheduling (Greedy, PSO, MOMPSO, MOMPSO-GA)
All four schedulers now decide from live data instead of two static numbers. The host sees, per worker: CPU load, free RAM, battery and charging, thermal status, Wi-Fi signal (Android), measured bandwidth and inference time, queue depth, recent latency and a power class by device model. Workers report health every 5 s over MQTT and with every finished unit.
- **Shared model** (`lib/services/schedulers/scheduling_model.dart`): the health score is the DetectNet `hScore` formula driven by live values; thermal, battery, memory, Wi-Fi signal and recently failed units derate a phone's capacity; phones at <=5% battery (unplugged), critical thermal state, low memory or repeatedly failed units (timeouts or reported errors) get no new work (unless every phone is in that state); each assignment lengthens that phone's queue, which spreads a batch.
- **Algorithms** keep the structure of the `Parikshit` versions and DetectNet: Greedy = earliest estimated finish; PSO = lightweight swarm over health scores; MOMPSO = weighted health / latency / queue / energy; MOMPSO-GA = MOMPSO plus 70/30 blend and mutation. Default MOMPSO weights are the DetectNet ones scaled by 0.8 with 0.2 for energy (`ObjectiveWeights`).
- **Robustness:** units not finished within 60 s are requeued; a worker whose download or inference fails reports it and the unit is requeued at once (a failure is never counted as a finished image), and a unit that fails 3 times is skipped so the job can finish; silent phones are dropped from planning; a shared dataset ZIP is extracted once and images are served from disk; `/admin/scheduler_logs` entries include a per-phone trace of why work went where.
- **Limits:** PSO and MOMPSO-GA are DetectNet's heuristics (PSO's fitness reduces to ranking by health; GA's closest-to-blend pick selects the top mutated score), not literature-faithful multi-objective PSO/GA. The thresholds in `HealthPolicy` are heuristics to calibrate. CPU load is the app's own process CPU. The Android Kotlin additions could not be compiled in the authoring environment.

## Basic troubleshooting (non-technical)
- If you can't connect, make sure both devices are on the same Wi‑Fi network.
- Check the IP address shown on the broker device and enter it exactly on the client device.
- If messages don’t appear, make sure the client tapped "Subscribe" before the other device published a message.
- If downloads fail, try again — network issues are common on busy Wi‑Fi.

## Safety & privacy notes (important for anyone)
- The app uses your local Wi‑Fi. Files and messages stay inside your local network unless you deliberately share them outside.
- Do not share the broker IP on public networks you don't control.

---

## Quick technical appendix (optional)
If you are curious or want to run the project from source, here are a few short notes for technical users:

- The app uses MQTT for messaging. It can run an embedded broker (so your device becomes the server) or act as a client that connects to a broker.
- Files are served by a small local HTTP server on the broker device; messages only carry the file link (not the full file).
- To run from source:
  1. Install Flutter and set up your platform (Android or iOS).
  2. In the project folder run: `flutter pub get` then `flutter run`.

If you'd like, we can add back a full developer section with dependency versions and code structure.

_This README focuses on how to use the app and what to expect. The app was built to demonstrate simple, local device-to-device messaging and file sharing on a home or lab Wi‑Fi network._
