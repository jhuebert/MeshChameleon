import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/ble_device_link.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _hostController = TextEditingController(text: '192.168.1.100');
  final _portController = TextEditingController(text: '5000');
  bool _scanning = false;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _connectTcp() async {
    final app = context.read<AppState>();
    await app.connectTcp(
      host: _hostController.text.trim(),
      tcpPort: int.tryParse(_portController.text.trim()),
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _connectBle(BluetoothDevice device) async {
    final app = context.read<AppState>();
    await app.connectBle(device);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Connect device')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('WiFi / Ethernet companion', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _hostController,
            decoration: const InputDecoration(labelText: 'Host'),
          ),
          TextField(
            controller: _portController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Port'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: app.busy ? null : _connectTcp,
            child: const Text('Connect over TCP'),
          ),
          const Divider(height: 40),
          const Text('BLE companion (NUS)', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (!_scanning)
            OutlinedButton.icon(
              icon: const Icon(Icons.search),
              label: const Text('Scan for MeshCore devices'),
              onPressed: () => setState(() => _scanning = true),
            ),
          if (_scanning)
            StreamBuilder<List<ScanResult>>(
              stream: MeshCoreUuids.scanForDevices(),
              builder: (context, snapshot) {
                final results = snapshot.data ?? const <ScanResult>[];
                if (results.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: Text('Scanning…')),
                  );
                }
                return Column(
                  children: [
                    for (final r in results)
                      ListTile(
                        title: Text(r.device.platformName.isEmpty
                            ? r.device.remoteId.toString()
                            : r.device.platformName),
                        subtitle: Text('RSSI ${r.rssi}'),
                        onTap: app.busy ? null : () => _connectBle(r.device),
                      ),
                  ],
                );
              },
            ),
          if (app.busy) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
