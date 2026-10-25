import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'screens/connect_screen.dart';
import 'screens/identity_screen.dart';
import 'screens/log_screen.dart';
import 'services/foreground_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ForegroundService().initialize();
  runApp(const ProxyApp());
}

class ProxyApp extends StatelessWidget {
  const ProxyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..loadIdentity(),
      child: MaterialApp(
        title: 'MeshChameleon',
        theme: ThemeData(
          colorSchemeSeed: Colors.teal,
          brightness: Brightness.light,
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.teal,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        themeMode: ThemeMode.system,
        home: const HomeScreen(),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final identity = app.identity;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset(
              'assets/branding/icon.png',
              width: 32,
              height: 32,
            ),
            const SizedBox(width: 8),
            const Text('MeshChameleon'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.receipt_long),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const LogScreen())),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(app: app, identityLabel: identity == null
              ? 'None'
              : '#${identity.publicKey.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: Icon(app.deviceConnected ? Icons.bluetooth_connected : Icons.bluetooth),
              title: const Text('Device link'),
              subtitle: Text(app.deviceLabel ?? 'Not connected'),
              trailing: app.deviceConnected
                  ? TextButton(
                      onPressed: app.busy ? null : app.disconnectDevice,
                      child: const Text('Disconnect'),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const ConnectScreen())),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.key),
              title: const Text('Identity'),
              subtitle: Text(identity == null ? 'Not set' : 'Ed25519'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const IdentityScreen())),
            ),
          ),
          Card(
            child: SwitchListTile(
              title: const Text('Proxy server'),
              subtitle: Text(
                app.proxyStatus == ProxyStatus.running
                    ? 'Listening on port ${app.port}'
                    : 'Stopped',
              ),
              value: app.proxyStatus == ProxyStatus.running,
              onChanged: app.busy
                  ? null
                  : (value) async {
                      if (value) {
                        await app.startProxy();
                      } else {
                        await app.stopProxy();
                      }
                    },
            ),
          ),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.restart_alt),
              title: const Text('Resume on launch'),
              subtitle: const Text(
                  'Reconnect the last device and restart the proxy when the app opens'),
              value: app.autoResume,
              onChanged:
                  app.busy ? null : (value) => app.setAutoResume(value),
            ),
          ),
          _ProxyPortCard(port: app.port),
          const _BatteryOptimizationCard(),
          if (app.busy) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}

class _ProxyPortCard extends StatefulWidget {
  const _ProxyPortCard({required this.port});

  final int port;

  @override
  State<_ProxyPortCard> createState() => _ProxyPortCardState();
}

class _ProxyPortCardState extends State<_ProxyPortCard> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.port.toString());
  }

  @override
  void didUpdateWidget(_ProxyPortCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.port != widget.port && !_focusNode.hasFocus) {
      _controller.text = widget.port.toString();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final app = context.read<AppState>();
    final value = int.tryParse(_controller.text.trim());
    if (value == null || !await app.setProxyPort(value)) {
      _controller.text = app.port.toString();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a port between 1 and 65535')),
        );
      }
    }
    if (mounted) FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final enabled = app.proxyStatus == ProxyStatus.stopped && !app.busy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.settings_ethernet),
            const SizedBox(width: 16),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                enabled: enabled,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Proxy server port',
                  helperText: 'Clients connect to this TCP port',
                ),
                onSubmitted: (_) => _save(),
              ),
            ),
            IconButton(
              onPressed: enabled ? _save : null,
              icon: const Icon(Icons.check),
              tooltip: 'Save port',
            ),
          ],
        ),
      ),
    );
  }
}

/// Prompts for a battery-optimization exemption, the main M0 reliability
/// control: without it, Doze/OEM battery managers can suspend the background
/// device link and proxy. Android-only.
class _BatteryOptimizationCard extends StatefulWidget {
  const _BatteryOptimizationCard();

  @override
  State<_BatteryOptimizationCard> createState() =>
      _BatteryOptimizationCardState();
}

class _BatteryOptimizationCardState extends State<_BatteryOptimizationCard>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().refreshBatteryOptimizationStatus();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user may toggle the exemption in system settings, so re-check on
    // return to the foreground.
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<AppState>().refreshBatteryOptimizationStatus();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final app = context.watch<AppState>();
    final ignored = app.batteryOptimizationsIgnored;
    return Card(
      child: ListTile(
        leading: Icon(
          ignored == true ? Icons.battery_saver : Icons.battery_alert,
        ),
        title: const Text('Battery optimization'),
        subtitle: Text(
          ignored == null
              ? 'Checking…'
              : ignored
                  ? 'Exempt — the background link runs reliably'
                  : 'Optimized — the OS may throttle the background link',
        ),
        trailing: ignored == false
            ? TextButton(
                onPressed: app.requestBatteryOptimizationExemption,
                child: const Text('Disable'),
              )
            : null,
      ),
    );
  }
}

String _batteryDiagnosticText(AppState app) {
  final age = app.batterySampleAgeSeconds;
  if (age == null) return 'Radio battery: waiting for first sample';
  final status = app.batteryStale ? 'stale' : 'fresh';
  return 'Radio battery: $status sample (${age}s old)';
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.app, required this.identityLabel});

  final AppState app;
  final String identityLabel;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Identity: $identityLabel',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Device: ${app.deviceConnected ? 'connected' : 'disconnected'}'),
            Text('Proxy: ${app.proxyStatus.name}'
                '${app.proxyStatus == ProxyStatus.running ? ' (port ${app.port})' : ''}'),
            if (app.deviceConnected)
              Text(_batteryDiagnosticText(app)),
          ],
        ),
      ),
    );
  }
}
