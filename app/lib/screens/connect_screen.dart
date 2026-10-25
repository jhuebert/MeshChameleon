import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/ble_device_link.dart';
import '../services/device_capabilities.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, this.capabilities});

  /// Overrides the detected platform capabilities (tests).
  final DeviceCapabilities? capabilities;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _hostController = TextEditingController(text: '192.168.1.100');
  final _portController = TextEditingController(text: '5000');
  bool _scanning = false;
  late final Stream<List<ScanResult>> _scanResults;
  late final DeviceCapabilities _capabilities =
      widget.capabilities ?? DeviceCapabilities.current();

  @override
  void initState() {
    super.initState();
    // Reading scan results reaches the plugin, which is absent off mobile.
    if (_capabilities.supportsBle) {
      _scanResults = MeshCoreUuids.scanResults;
    }
  }

  @override
  void dispose() {
    unawaited(_stopScan());
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() => _scanning = true);
    try {
      await MeshCoreUuids.startScan();
    } catch (_) {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _stopScan() async {
    if (!_capabilities.supportsBle) return;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  Future<void> _connectSimulated() async {
    final app = context.read<AppState>();
    await app.connectSimulated();
    if (mounted) Navigator.of(context).pop();
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
    await _stopScan();
    await app.connectBle(device);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(app.cancelPendingConnection());
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Connect device')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (app.deviceConnected)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.bluetooth_connected),
                  title: Text(app.deviceLabel ?? 'Connected device'),
                  trailing: TextButton(
                    onPressed: app.busy ? null : app.disconnectDevice,
                    child: const Text('Disconnect'),
                  ),
                ),
              ),
            const Text('Network companion',
                style: TextStyle(fontWeight: FontWeight.bold)),
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
            if (_capabilities.supportsBle) ...[
              const Divider(height: 40),
              const Text('Bluetooth companion',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (!_scanning)
                OutlinedButton.icon(
                  icon: const Icon(Icons.search),
                  label: const Text('Scan for MeshCore devices'),
                  onPressed: _startScan,
                ),
              if (_scanning)
                StreamBuilder<List<ScanResult>>(
                  stream: _scanResults,
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
                            onTap:
                                app.busy ? null : () => _connectBle(r.device),
                          ),
                      ],
                    );
                  },
                ),
            ],
            if (_capabilities.supportsSimulatedCompanion) ...[
              const Divider(height: 40),
              const Text('Simulated companion (development)',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'Runs the proxy against an in-memory companion. No radio or '
                'BLE hardware is used and packets never leave the app.',
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.science_outlined),
                label: const Text('Connect simulated companion'),
                onPressed: app.busy ? null : _connectSimulated,
              ),
            ],
            if (app.busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
