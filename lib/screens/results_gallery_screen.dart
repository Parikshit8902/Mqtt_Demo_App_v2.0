import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/utils/http_helper.dart';
import '../widgets/bounding_box_painter.dart';

class ResultsGalleryScreen extends StatefulWidget {
  final String serverBase;
  final String jobId;

  const ResultsGalleryScreen({super.key, required this.serverBase, required this.jobId});

  @override
  State<ResultsGalleryScreen> createState() => _ResultsGalleryScreenState();
}

class _ResultsGalleryScreenState extends State<ResultsGalleryScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _results = [];

  @override
  void initState() {
    super.initState();
    _fetchResults();
  }

  Future<void> _fetchResults() async {
    setState(() => _loading = true);
    try {
      try {
        final url = Uri.parse('${widget.serverBase}/admin/job_status');
        final j = await httpGetJson(url) as Map<String, dynamic>?;
        final recent = (j?['recent_results'] as Map<String, dynamic>?) ?? {};
        final list = (recent[widget.jobId] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
        setState(() => _results = List<Map<String, dynamic>>.from(list));
      } catch (_) {
        // ignore errors; _results will remain empty
      }
    } catch (_) {}
    setState(() => _loading = false);
  }

  Future<ui.Image?> _decodeImage(Uint8List bytes) async {
    try {
      final c = Completer<ui.Image>();
      ui.decodeImageFromList(bytes, (i) => c.complete(i));
      return await c.future;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Results — ${widget.jobId}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _results.isEmpty
              ? const Center(child: Text('No results available'))
              : RefreshIndicator(
                  onRefresh: _fetchResults,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _results.length,
                    itemBuilder: (context, idx) {
                      final r = _results[idx];
                      final fileUrl = (r['file_url'] ?? r['fileUrl'] ?? r['result_uri'] ?? '') as String;
                      final detections = r['detections'] ?? r['boxes'] ?? [];
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                              Expanded(child: Text('Client: ${r['i'] ?? r['client_id'] ?? ''}  •  unit: ${r['unit_index'] ?? r['unitIndex'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
                              Text(r['received_at'] ?? '', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                            ]),
                            const SizedBox(height: 10),
                            if (fileUrl.isNotEmpty)
                              FutureBuilder<http.Response>(
                                future: http.get(Uri.parse(fileUrl)),
                                builder: (context, snap) {
                                  if (!snap.hasData) return const SizedBox(height: 220, child: Center(child: CircularProgressIndicator()));
                                  final resp = snap.data!;
                                  if (resp.statusCode != 200) return Text('Failed to load image: ${resp.statusCode}');
                                  final bytes = resp.bodyBytes;
                                  return FutureBuilder<ui.Image?>(
                                    future: _decodeImage(bytes),
                                    builder: (c2, imgSnap) {
                                      if (!imgSnap.hasData) return const SizedBox(height: 220, child: Center(child: CircularProgressIndicator()));
                                      final img = imgSnap.data!;
                                      final size = Size(img.width.toDouble(), img.height.toDouble());
                                      return ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: Container(
                                          color: Colors.black12,
                                          constraints: const BoxConstraints(maxHeight: 320),
                                          child: Stack(children: [
                                            Positioned.fill(child: FittedBox(fit: BoxFit.contain, child: Image.memory(bytes, fit: BoxFit.contain))),
                                            Positioned.fill(child: CustomPaint(painter: BoundingBoxPainter(detections as List<dynamic>, size, showLabels: true))),
                                          ]),
                                        ),
                                      );
                                    },
                                  );
                                },
                              )
                            else
                              const Text('No file URL provided for this result'),
                            const SizedBox(height: 8),
                            Wrap(spacing: 8, children: [
                              if (detections.isNotEmpty) Chip(label: Text('${detections.length} detections')),
                            ])
                          ]),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
