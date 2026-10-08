import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/session_link.dart';

/// Full-screen camera that reads the QR code the host shows and returns its
/// [SessionLink] (host address and PIN), or null if the user backs out.
class ScanSessionScreen extends StatefulWidget {
  const ScanSessionScreen({super.key});

  @override
  State<ScanSessionScreen> createState() => _ScanSessionScreenState();
}

class _ScanSessionScreenState extends State<ScanSessionScreen> {
  bool _done = false;
  String? _rejected;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final code in capture.barcodes) {
      final raw = code.rawValue;
      if (raw == null) continue;
      final link = SessionLink.parse(raw);
      if (link != null) {
        _done = true;
        Navigator.of(context).pop(link);
        return;
      }
      if (_rejected != raw) setState(() => _rejected = raw);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan the host\'s QR code')),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Camera unavailable (${error.errorCode.name}). Allow camera access, or type the address and PIN instead.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          if (_rejected != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: Container(
                padding: const EdgeInsets.all(12),
                color: Colors.black87,
                child: const Text(
                  'That QR code is not a session code. Scan the one on the host\'s session screen.',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
