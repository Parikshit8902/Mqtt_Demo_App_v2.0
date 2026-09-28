import 'package:flutter/material.dart';
import '../services/mqtt_service.dart';
import 'model_management_screen.dart';

class SettingsScreen extends StatefulWidget {
  final MqttService mqttService;

  const SettingsScreen({
    super.key,
    required this.mqttService,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _buildSection(
            title: 'Connection Settings',
            icon: Icons.wifi_outlined,
            children: [
              _buildConnectionInfo(),
            ],
          ),
          const SizedBox(height: 32),
          _buildSection(
            title: 'File Sharing',
            icon: Icons.folder_shared_outlined,
            children: [
              _buildFileServerInfo(),
            ],
          ),
          const SizedBox(height: 32),
          _buildSection(
            title: 'MQTT Configuration',
            icon: Icons.settings_input_antenna_outlined,
            children: [
              _buildMqttInfo(),
            ],
          ),
          const SizedBox(height: 32),
          _buildSection(
            title: 'Model Management',
            icon: Icons.model_training,
            children: [
              _buildModelManagementInfo(),
            ],
          ),
          const SizedBox(height: 32),
          _buildSection(
            title: 'About',
            icon: Icons.info_outline,
            children: [
              _buildAboutInfo(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: Colors.grey.shade700),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.black,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ...children,
      ],
    );
  }

  Widget _buildConnectionInfo() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInfoRow('Connection Status', 
            widget.mqttService.isConnected ? 'Connected' : 'Disconnected',
            widget.mqttService.isConnected ? Colors.green : Colors.red),
          const SizedBox(height: 8),
          if (widget.mqttService.isConnected) ...[
            _buildInfoRow('Broker IP', widget.mqttService.brokerIp.isNotEmpty ? widget.mqttService.brokerIp : 'Unknown'),
            const SizedBox(height: 8),
          ],
          _buildInfoRow('Broker Running', 
            widget.mqttService.isBrokerRunning ? 'Yes' : 'No',
            widget.mqttService.isBrokerRunning ? Colors.green : Colors.grey),
          const SizedBox(height: 8),
          _buildInfoRow('Current Mode', _getModeText()),
        ],
      ),
    );
  }

  Widget _buildFileServerInfo() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInfoRow('File Server', 
            widget.mqttService.isFileServerRunning ? 'Running' : 'Stopped',
            widget.mqttService.isFileServerRunning ? Colors.green : Colors.grey),
          const SizedBox(height: 8),
          if (widget.mqttService.isFileServerRunning) ...[
            _buildInfoRow('Active Downloads', widget.mqttService.activeDownloads.length.toString()),
          ],
        ],
      ),
    );
  }

  Widget _buildMqttInfo() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInfoRow('Client ID', widget.mqttService.clientManager.clientId),
          const SizedBox(height: 8),
          _buildInfoRow('Subscribed Topics', '${widget.mqttService.subscribedTopics.length}'),
          const SizedBox(height: 8),
          _buildInfoRow('Connected Clients', '${widget.mqttService.connectedClientsCount}'),
          const SizedBox(height: 8),
          _buildInfoRow('Default Topic', widget.mqttService.defaultTopic),
          const SizedBox(height: 8),
          _buildInfoRow('Share Topic', widget.mqttService.shareTopic),
        ],
      ),
    );
  }

  String _getModeText() {
    switch (widget.mqttService.currentMode) {
      case AppMode.broker:
        return 'Broker (Hosting)';
      case AppMode.client:
        return 'Client (Connected)';
      case AppMode.none:
        return 'None';
    }
  }

  Widget _buildAboutInfo() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInfoRow('App Name', 'MQTT Demo'),
          const SizedBox(height: 8),
          _buildInfoRow('Version', '1.0.0'),
          const SizedBox(height: 8),
          _buildInfoRow('Developer', 'Vishal Dhoriya'),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, [Color? valueColor]) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              color: valueColor ?? Colors.black,
              fontWeight: FontWeight.w500,
              fontFamily: value.contains('http') || value.contains(':') ? 'monospace' : null,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildModelManagementInfo() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Manage YOLO models and run object detection on images.',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const ModelManagementScreen(),
                ),
              );
            },
            child: const Text('Open Model Management'),
          ),
        ],
      ),
    );
  }
}
