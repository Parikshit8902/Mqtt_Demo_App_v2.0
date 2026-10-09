/// Application-layer byte counters.
///
/// These count the *payload* bytes this app asks the network stack to move
/// (MQTT payloads, HTTP bodies). The OS-level counters in `PerformanceService`
/// (TrafficStats on Android) count everything on the wire, including TCP/IP/
/// Wi-Fi framing, HTTP headers, retransmissions and discovery traffic, so:
///
///   protocol overhead = on-wire bytes - payload bytes counted here
///
/// Channels separate *useful work* (`httpData`: images / models) from *control*
/// (`httpControl`: assignments, results, warm-up), MQTT messaging, and the
/// monitoring traffic produced by the metrics publisher itself (`mqttMetrics`).
class TrafficChannel {
  static const mqtt = 'mqtt';
  static const mqttMetrics = 'mqtt_metrics';
  static const httpControl = 'http_control';
  static const httpData = 'http_data';

  static const all = [mqtt, mqttMetrics, httpControl, httpData];
}

class TrafficCounter {
  TrafficCounter._();
  static final TrafficCounter instance = TrafficCounter._();

  final Map<String, int> _tx = {};
  final Map<String, int> _rx = {};

  /// Application-level messages (one MQTT publish, one HTTP request or response),
  /// as opposed to bytes. Network *packets* come from the OS counters instead.
  final Map<String, int> _txMsgs = {};
  final Map<String, int> _rxMsgs = {};

  /// Estimated MQTT framing (fixed header + topic) that is not part of the payload.
  int mqttFramingTx = 0;
  int mqttFramingRx = 0;

  /// Bytes the HTTP server on this phone sent to / received from each peer IP.
  final Map<String, int> peerTx = {};
  final Map<String, int> peerRx = {};

  void addTx(String channel, int bytes, {String? peer}) {
    if (bytes <= 0) return;
    _tx[channel] = (_tx[channel] ?? 0) + bytes;
    if (peer != null) peerTx[peer] = (peerTx[peer] ?? 0) + bytes;
  }

  void addRx(String channel, int bytes, {String? peer}) {
    if (bytes <= 0) return;
    _rx[channel] = (_rx[channel] ?? 0) + bytes;
    if (peer != null) peerRx[peer] = (peerRx[peer] ?? 0) + bytes;
  }

  void countTxMsg(String channel, [int n = 1]) => _txMsgs[channel] = (_txMsgs[channel] ?? 0) + n;

  void countRxMsg(String channel, [int n = 1]) => _rxMsgs[channel] = (_rxMsgs[channel] ?? 0) + n;

  int txMsgs(String channel) => _txMsgs[channel] ?? 0;
  int rxMsgs(String channel) => _rxMsgs[channel] ?? 0;

  /// MQTT 3.1.1 PUBLISH (QoS 0) framing: 1 byte fixed header + 1..4 bytes
  /// remaining length + 2 byte topic length + topic. Excludes TCP/IP.
  static int mqttFraming(String topic, int payloadBytes) {
    final remaining = 2 + topic.length + payloadBytes;
    final remLenBytes = remaining < 128 ? 1 : remaining < 16384 ? 2 : remaining < 2097152 ? 3 : 4;
    return 1 + remLenBytes + 2 + topic.length;
  }

  int tx(String channel) => _tx[channel] ?? 0;
  int rx(String channel) => _rx[channel] ?? 0;
  int get totalTx => _tx.values.fold(0, (a, b) => a + b);
  int get totalRx => _rx.values.fold(0, (a, b) => a + b);
  int get totalPayload => totalTx + totalRx;

  Map<String, dynamic> toJson() => {
        'tx': Map<String, int>.from(_tx),
        'rx': Map<String, int>.from(_rx),
        'tx_msgs': Map<String, int>.from(_txMsgs),
        'rx_msgs': Map<String, int>.from(_rxMsgs),
        'mqtt_framing_tx': mqttFramingTx,
        'mqtt_framing_rx': mqttFramingRx,
        'peer_tx': Map<String, int>.from(peerTx),
        'peer_rx': Map<String, int>.from(peerRx),
      };

  void reset() {
    _tx.clear();
    _rx.clear();
    _txMsgs.clear();
    _rxMsgs.clear();
    peerTx.clear();
    peerRx.clear();
    mqttFramingTx = 0;
    mqttFramingRx = 0;
  }
}
