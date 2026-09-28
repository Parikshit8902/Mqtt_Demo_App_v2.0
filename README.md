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
