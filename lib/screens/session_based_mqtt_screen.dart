import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../services/mqtt_service.dart';
import '../widgets/compact_device_ip_display.dart';
import 'navigation_container.dart';
import 'client_navigation_container.dart';
import 'settings_screen.dart';

class SessionBasedMqttScreen extends StatefulWidget {
  const SessionBasedMqttScreen({super.key});

  @override
  State<SessionBasedMqttScreen> createState() => _SessionBasedMqttScreenState();
}

class _SessionBasedMqttScreenState extends State<SessionBasedMqttScreen> {
  final MqttService _mqttService = MqttService();
  SessionState _currentState = SessionState.home;

  /// Helper method to log UI interactions
  void _logUI(String message) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    if (kDebugMode) {
      print('[$timestamp] UI: $message');
    }
  }

  @override
  void initState() {
    super.initState();
    _logUI('🎬 Initializing Session-Based MQTT Demo App');
    _mqttService.addListener(_onMqttServiceChanged);
  }
  void _onMqttServiceChanged() {
  // _logUI('📊 MQTT Service state changed - updating UI');
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) setState(() {});
  });
}

  // void _onMqttServiceChanged() {
  //   _logUI('📊 MQTT Service state changed - updating UI');
  //   setState(() {});
  // }

  @override
  void dispose() {
    _logUI('🧹 Disposing Session-Based MQTT Demo App');
    _mqttService.removeListener(_onMqttServiceChanged);
    _mqttService.dispose();
    super.dispose();
  }

  void _navigateToHostSession() {
    _logUI('🎯 User selected Host Session');
    setState(() {
      _currentState = SessionState.hosting;
    });
  }

  void _navigateToJoinSession() {
    _logUI('🎯 User selected Join Session');
    setState(() {
      _currentState = SessionState.joining;
    });
  }

  void _navigateToHome() {
    _logUI('🏠 User returned to home');
    setState(() {
      _currentState = SessionState.home;
    });
  }

  void _openSettings() {
    _logUI('⚙️ User opened settings');
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SettingsScreen(mqttService: _mqttService),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('MQTT Sessions'),
        centerTitle: true,
        leading: _currentState != SessionState.home
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _navigateToHome,
                tooltip: 'Back to Home',
              )
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
            tooltip: 'Settings',
          ),
        ],
      ),
      body: Column(
        children: [
          // Compact Device IP Display (always visible)
          const CompactDeviceIPDisplay(),
          
          // Main Content Area
          Expanded(
            child: _buildCurrentScreen(),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentScreen() {
    switch (_currentState) {
      case SessionState.home:
        return SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 40),
              _buildSessionButtons(),
              const SizedBox(height: 40),
            ],
          ),
        );
      case SessionState.hosting:
        return NavigationContainer(
          mqttService: _mqttService,
          onBackToHome: _navigateToHome,
        );
      case SessionState.joining:
        return ClientNavigationContainer(
          mqttService: _mqttService,
          onBackToHome: _navigateToHome,
        );
    }
  }

  Widget _buildSessionButtons() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          // Host Session Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _navigateToHostSession,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              child: const Text(
                'Host a Session',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Join Session Button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _navigateToJoinSession,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.black,
                side: const BorderSide(color: Colors.black),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              child: const Text(
                'Join a Session',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ... existing methods ...
}

enum SessionState { home, hosting, joining }
