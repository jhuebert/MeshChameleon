import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/ble_device_link.dart';
import '../services/device_capabilities.dart';
import '../services/network_connection_store.dart';
import '../services/session_store.dart';

enum _ConnectTab {
  bluetooth('Bluetooth'),
  network('Network'),
  simulated('Simulated');

  const _ConnectTab(this.label);

  final String label;
}

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, this.capabilities});

  /// Overrides the detected platform capabilities (tests).
  final DeviceCapabilities? capabilities;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen>
    with SingleTickerProviderStateMixin {
  late final DeviceCapabilities _capabilities =
      widget.capabilities ?? DeviceCapabilities.current();
  late final List<_ConnectTab> _tabs;
  final _formKey = GlobalKey<FormState>();
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  TabController? _tabController;
  late final Stream<List<ScanResult>> _scanResults;
  bool _scanning = false;
  int _lastTabIndex = 0;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    final lastKind = app.lastSession?.kind;
    _tabs = [
      if (_capabilities.supportsBle) _ConnectTab.bluetooth,
      _ConnectTab.network,
      if (_capabilities.supportsSimulatedCompanion) _ConnectTab.simulated,
    ];
    _setInitialTarget(app);
    if (_tabs.length > 1) {
      final controller = TabController(
        length: _tabs.length,
        vsync: this,
        initialIndex: _initialIndex(lastKind),
      );
      _lastTabIndex = controller.index;
      controller.addListener(_handleTabChanged);
      _tabController = controller;
    }
    // Reading scan results reaches the plugin, which is absent off mobile.
    if (_capabilities.supportsBle) {
      _scanResults = MeshCoreUuids.scanResults;
    }
  }

  @override
  void dispose() {
    _tabController?.removeListener(_handleTabChanged);
    _tabController?.dispose();
    if (_scanning) unawaited(_stopScan(updateUi: false));
    _scanning = false;
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  void _setInitialTarget(AppState app) {
    final saved = app.savedNetworkConnections;
    if (saved.isNotEmpty) {
      _hostController.text = saved.first.host;
      _portController.text = saved.first.port.toString();
      return;
    }
    final session = app.lastSession;
    if (session != null &&
        session.kind == DeviceTargetKind.tcp &&
        session.host != null) {
      _hostController.text = session.host!;
      _portController.text = session.devicePort.toString();
      return;
    }
    _hostController.text = '192.168.1.100';
    _portController.text = defaultCompanionPort.toString();
  }

  int _initialIndex(DeviceTargetKind? lastKind) {
    final preferred = switch (lastKind) {
      DeviceTargetKind.ble => _ConnectTab.bluetooth,
      DeviceTargetKind.tcp => _ConnectTab.network,
      DeviceTargetKind.simulated => _ConnectTab.simulated,
      null => null,
    };
    if (preferred != null) {
      final index = _tabs.indexOf(preferred);
      if (index >= 0) return index;
    }
    final bluetoothIndex = _tabs.indexOf(_ConnectTab.bluetooth);
    return bluetoothIndex >= 0
        ? bluetoothIndex
        : _tabs.indexOf(_ConnectTab.network);
  }

  void _handleTabChanged() {
    final controller = _tabController;
    if (controller == null || controller.index == _lastTabIndex) return;
    _lastTabIndex = controller.index;
    if (_tabs[controller.index] != _ConnectTab.bluetooth && _scanning) {
      unawaited(_stopScan());
    }
  }

  Future<void> _startScan() async {
    setState(() => _scanning = true);
    try {
      await MeshCoreUuids.startScan();
    } catch (_) {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _stopScan({bool updateUi = true}) async {
    if (!_capabilities.supportsBle || !_scanning) return;
    if (updateUi && mounted) {
      setState(() => _scanning = false);
    }
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  String? _validateHost(String? value) =>
      (value ?? '').trim().isEmpty ? 'Enter a host' : null;

  String? _validatePort(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return 'Enter a port';
    final port = int.tryParse(text);
    if (port == null || port < 1 || port > 65535) {
      return 'Enter a port between 1 and 65535';
    }
    return null;
  }

  Future<void> _connectTcp() async {
    final app = context.read<AppState>();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final host = _hostController.text.trim();
    final port = int.parse(_portController.text.trim());
    FocusScope.of(context).unfocus();
    final ok = await app.connectTcp(host: host, tcpPort: port);
    _finishConnection(
      ok,
      'Could not connect to ${formatNetworkAddress(host, port)}. '
      'See the log for details.',
    );
  }

  Future<void> _connectSaved(SavedNetworkConnection connection) async {
    _hostController.text = connection.host;
    _portController.text = connection.port.toString();
    await _connectTcp();
  }

  Future<void> _deleteSaved(SavedNetworkConnection connection) async {
    final app = context.read<AppState>();
    final ok = await app.removeSavedNetworkConnection(connection);
    if (!mounted) return;
    if (!ok) {
      _showFailure('Could not remove the saved connection.');
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Removed ${connection.displayAddress}'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => unawaited(_restoreSaved(connection)),
        ),
      ),
    );
  }

  Future<void> _restoreSaved(SavedNetworkConnection connection) async {
    if (!mounted) return;
    final app = context.read<AppState>();
    final ok = await app.restoreSavedNetworkConnection(connection);
    if (!ok && mounted) {
      _showFailure('Could not restore the saved connection.');
    }
  }

  Future<void> _connectBle(BluetoothDevice device) async {
    final app = context.read<AppState>();
    final name = _deviceName(device);
    await _stopScan();
    final ok = await app.connectBle(device);
    _finishConnection(
      ok,
      'Could not connect to $name. See the log for details.',
    );
  }

  Future<void> _connectSimulated() async {
    final app = context.read<AppState>();
    final ok = await app.connectSimulated();
    _finishConnection(
      ok,
      'Could not start the simulated companion. See the log for details.',
    );
  }

  void _finishConnection(bool connected, String failureMessage) {
    if (!mounted) return;
    if (connected) {
      Navigator.of(context).pop();
    } else {
      _showFailure(failureMessage);
    }
  }

  void _showFailure(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  static String _deviceName(BluetoothDevice device) =>
      device.platformName.isEmpty
          ? device.remoteId.toString()
          : device.platformName;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final controller = _tabController;
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(app.cancelPendingConnection());
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Connect device')),
        body: Column(
          children: [
            if (app.deviceConnected)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: _ConnectedDeviceCard(app: app),
              ),
            if (controller != null)
              TabBar(
                controller: controller,
                tabs: [
                  for (final tab in _tabs) Tab(text: tab.label),
                ],
              ),
            if (app.busy) const LinearProgressIndicator(),
            Expanded(
              child: controller == null
                  ? _buildTab(app, _tabs.single)
                  : TabBarView(
                      controller: controller,
                      children: [
                        for (final tab in _tabs) _buildTab(app, tab),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTab(AppState app, _ConnectTab tab) => switch (tab) {
        _ConnectTab.bluetooth => _buildBluetoothTab(app),
        _ConnectTab.network => _buildNetworkTab(app),
        _ConnectTab.simulated => _buildSimulatedTab(app),
      };

  Widget _buildBluetoothTab(AppState app) {
    if (!_capabilities.supportsBle) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Bluetooth companion',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text('Scan for a nearby MeshCore companion over Bluetooth.'),
        const SizedBox(height: 16),
        if (!_scanning)
          OutlinedButton.icon(
            icon: const Icon(Icons.search),
            label: const Text('Scan for MeshCore devices'),
            onPressed: app.busy ? null : _startScan,
          )
        else ...[
          Row(
            children: [
              const Expanded(child: Text('Scanning…')),
              TextButton(
                onPressed: _stopScan,
                child: const Text('Stop scan'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          StreamBuilder<List<ScanResult>>(
            stream: _scanResults,
            builder: (context, snapshot) {
              final results = snapshot.data ?? const <ScanResult>[];
              return Column(
                children: [
                  for (final result in results)
                    ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(_deviceName(result.device)),
                      subtitle: Text('RSSI ${result.rssi}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: app.busy ? null : () => _connectBle(result.device),
                    ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }

  Widget _buildNetworkTab(AppState app) {
    final saved = app.savedNetworkConnections;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Network companion',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text('Connect to a companion over Wi-Fi or Ethernet.'),
        const SizedBox(height: 16),
        Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _hostController,
                decoration: const InputDecoration(labelText: 'Host'),
                textInputAction: TextInputAction.next,
                validator: _validateHost,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _portController,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(labelText: 'Port'),
                validator: _validatePort,
                onFieldSubmitted: app.busy ? null : (_) => _connectTcp(),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: app.busy ? null : _connectTcp,
                child: const Text('Connect over TCP'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text('Saved connections',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (saved.isEmpty)
          const Text(
            'Successful network connections appear here for quick reconnects.',
          )
        else
          for (final connection in saved)
            _SavedConnectionCard(
              connection: connection,
              busy: app.busy,
              onTap: () => _connectSaved(connection),
              onDelete: () => _deleteSaved(connection),
            ),
      ],
    );
  }

  Widget _buildSimulatedTab(AppState app) {
    if (!_capabilities.supportsSimulatedCompanion) {
      return const SizedBox.shrink();
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Simulated companion',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          'Runs the proxy against an in-memory companion. No radio or BLE '
          'hardware is used and packets never leave the app.',
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          icon: const Icon(Icons.science_outlined),
          label: const Text('Connect simulated companion'),
          onPressed: app.busy ? null : _connectSimulated,
        ),
      ],
    );
  }
}

class _SavedConnectionCard extends StatelessWidget {
  const _SavedConnectionCard({
    required this.connection,
    required this.busy,
    required this.onTap,
    required this.onDelete,
  });

  final SavedNetworkConnection connection;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    return Card(
      child: ListTile(
        title: Text(connection.displayAddress),
        subtitle: Text(
          'Last connected '
          '${_relativeTime(connection.lastConnectedAt, localizations)}',
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Remove saved connection',
          onPressed: busy ? null : onDelete,
        ),
        onTap: busy ? null : onTap,
      ),
    );
  }
}

String _relativeTime(
  int lastConnectedAt,
  MaterialLocalizations localizations,
) {
  final connectedAt = DateTime.fromMillisecondsSinceEpoch(lastConnectedAt);
  final elapsed = DateTime.now().difference(connectedAt);
  if (elapsed.isNegative || elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inHours < 1) return _ago(elapsed.inMinutes, 'minute');
  if (elapsed.inDays < 1) return _ago(elapsed.inHours, 'hour');
  if (elapsed.inDays < 7) return _ago(elapsed.inDays, 'day');
  return localizations.formatShortDate(connectedAt);
}

String _ago(int value, String unit) =>
    '$value $unit${value == 1 ? '' : 's'} ago';

class _ConnectedDeviceCard extends StatelessWidget {
  const _ConnectedDeviceCard({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(_transportIcon(app.lastSession?.kind)),
        title: Text(app.deviceLabel ?? 'Connected device'),
        subtitle: const Text('Connected'),
        trailing: TextButton(
          onPressed: app.busy ? null : app.disconnectDevice,
          child: const Text('Disconnect'),
        ),
      ),
    );
  }

  static IconData _transportIcon(DeviceTargetKind? kind) => switch (kind) {
        DeviceTargetKind.ble => Icons.bluetooth_connected,
        DeviceTargetKind.tcp => Icons.lan,
        DeviceTargetKind.simulated => Icons.science_outlined,
        null => Icons.devices_other,
      };
}
