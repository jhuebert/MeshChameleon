import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'screens/connect_screen.dart';
import 'screens/identity_screen.dart';
import 'screens/log_screen.dart';

void main() {
  runApp(const ProxyApp());
}

class ProxyApp extends StatelessWidget {
  const ProxyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..loadIdentity(),
      child: MaterialApp(
        title: 'MeshCore Companion Proxy',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
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
        title: const Text('Companion Proxy'),
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
              trailing: const Icon(Icons.chevron_right),
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
          if (app.busy) const LinearProgressIndicator(),
          const SizedBox(height: 16),
          const Text('Recent log', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final line in app.logs.reversed.take(8))
            Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        ],
      ),
    );
  }
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
          ],
        ),
      ),
    );
  }
}
