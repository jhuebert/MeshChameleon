import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'screens/backup_screen.dart';
import 'screens/connect_screen.dart';
import 'screens/diagnostics_screen.dart';
import 'screens/identities_screen.dart';
import 'screens/log_screen.dart';
import 'services/build_info.dart';
import 'services/network_connection_store.dart';
import 'widgets/app_snack_bar.dart';
import 'widgets/app_surfaces.dart';
import 'widgets/device_target_icon.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final buildInfo = await BuildInfo.load();
  runApp(ProxyApp(buildInfo: buildInfo));
}

class ProxyApp extends StatelessWidget {
  const ProxyApp({super.key, required this.buildInfo});

  final BuildInfo buildInfo;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppViewState>(
      create: (_) => AppState(buildInfo: buildInfo)..loadIdentities(),
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

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The companion may be back in range after the session gave up on it.
      context.read<AppViewState>().rearmAfterLinkLoss();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppViewState>();
    final active = app.activeIdentity;
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
            tooltip: 'Log',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const LogScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'About & diagnostics',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DiagnosticsScreen()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(
            app: app,
            identityLabel: active == null
                ? 'None'
                : '${active.name} (#${active.prefixHex})',
          ),
          const SizedBox(height: 12),
          ActionTile(
            icon: deviceTargetIcon(
              app.deviceConnected ? app.lastSession?.kind : null,
            ),
            title: 'Device link',
            subtitle: _deviceSubtitle(app),
            trailing: app.deviceConnected
                ? TextButton(
                    onPressed: app.busy ? null : app.disconnectDevice,
                    child: const Text('Disconnect'),
                  )
                : app.deviceConnecting ||
                        app.deviceReconnecting ||
                        app.deviceWaiting
                    ? TextButton(
                        onPressed: app.cancelDeviceAttempt,
                        child: const Text('Cancel'),
                      )
                    : null,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ConnectScreen()),
            ),
          ),
          if (app.deviceWaiting) ...[
            const SizedBox(height: 8),
            Text(
              'Proxy stopped. It will restart automatically when the '
              'companion returns.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          ActionTile(
            icon: active == null ? Icons.key_off : Icons.key,
            title: active?.name ?? 'No identity',
            subtitle: active == null
                ? 'Create an identity'
                : '#${active.prefixHex}'
                    '${active.live ? ' · Live' : ''}',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const IdentitiesScreen()),
            ),
          ),
          _ProxyPortCard(port: app.port),
          Card(
            child: SwitchListTile(
              title: const Text('Proxy server'),
              subtitle: Text(
                app.proxyStatus == ProxyStatus.running
                    ? 'Listening on port ${app.port}'
                    : 'Stopped',
              ),
              value: app.proxyStatus == ProxyStatus.running,
              onChanged: app.busy ||
                      (!app.deviceConnected &&
                          app.proxyStatus != ProxyStatus.running)
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
                  'Reconnect the last device on launch (cold start only)'),
              value: app.autoResume,
              onChanged: app.busy ? null : (value) => app.setAutoResume(value),
            ),
          ),
          const _BatteryOptimizationCard(),
          const _PhoneTelemetryCard(),
          const _BackupCard(),
          if (app.busy) const LinearProgressIndicator(),
          const SizedBox(height: 8),
          _BuildFooter(buildInfo: app.buildInfo),
        ],
      ),
    );
  }
}

String _deviceSubtitle(AppViewState app) {
  final label = app.deviceLabel;
  return switch (app.devicePhase) {
    DeviceLinkPhase.connecting => 'Connecting…',
    DeviceLinkPhase.reconnecting => 'Reconnecting…',
    DeviceLinkPhase.waiting =>
      label == null ? 'Waiting for companion' : 'Waiting for $label',
    DeviceLinkPhase.connected => label ?? 'Connected',
    DeviceLinkPhase.disconnecting => 'Disconnecting…',
    DeviceLinkPhase.idle => 'Not connected',
  };
}

class _BuildFooter extends StatelessWidget {
  const _BuildFooter({required this.buildInfo});

  final BuildInfo buildInfo;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.center,
      child: TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const DiagnosticsScreen()),
        ),
        style: TextButton.styleFrom(
          foregroundColor: colors.onSurfaceVariant,
          textStyle: Theme.of(context).textTheme.bodySmall,
          minimumSize: const Size(48, 40),
        ),
        child: Text(
          'MeshChameleon ${buildInfo.footerLabel}',
          textAlign: TextAlign.center,
        ),
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
    final app = context.read<AppViewState>();
    final value = int.tryParse(_controller.text.trim());
    if (value == null ||
        !isValidTcpPort(value) ||
        !await app.setProxyPort(value)) {
      _controller.text = app.port.toString();
      if (mounted) {
        showAppSnackBar(
          context,
          'Enter a port between 1 and 65535',
          replace: false,
        );
      }
    }
    if (mounted) FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppViewState>();
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

/// Opens the Android battery-optimization settings, the main M0 reliability
/// control: without an unrestricted setting, Doze/OEM battery managers can
/// suspend the background device link and proxy. Android-only.
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
      if (mounted) {
        context.read<AppViewState>().refreshBatteryOptimizationStatus();
      }
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
      context.read<AppViewState>().refreshBatteryOptimizationStatus();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    final app = context.watch<AppViewState>();
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
                  ? 'Unrestricted — the background link is not throttled'
                  : 'Optimized — Android may throttle the background link. '
                      'Set MeshChameleon to Unrestricted in battery settings.',
        ),
        trailing: ignored == false
            ? TextButton(
                onPressed: app.openBatteryOptimizationSettings,
                child: const Text('Open settings'),
              )
            : null,
      ),
    );
  }
}

/// Phone battery and GPS controls for the active identity.
///
/// The switch writes the same `gps` custom variable the companion client uses;
/// mesh telemetry permissions still decide which contacts receive the data.
class _PhoneTelemetryCard extends StatefulWidget {
  const _PhoneTelemetryCard();

  @override
  State<_PhoneTelemetryCard> createState() => _PhoneTelemetryCardState();
}

class _PhoneTelemetryCardState extends State<_PhoneTelemetryCard>
    with WidgetsBindingObserver {
  late final TextEditingController _interval;

  @override
  void initState() {
    super.initState();
    _interval = TextEditingController();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppViewState>().refreshPhoneTelemetry();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _interval.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<AppViewState>().refreshPhoneTelemetry();
    }
  }

  Future<void> _requestLocation() async {
    final app = context.read<AppViewState>();
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Allow phone GPS?'),
        content: const Text(
          'MeshChameleon needs location access to include phone coordinates '
          'in adverts and location telemetry. Contacts still need location '
          'telemetry permission to receive them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (proceed == true) await app.requestPhoneLocationPermission();
  }

  Future<void> _saveInterval() async {
    final app = context.read<AppViewState>();
    final seconds = int.tryParse(_interval.text.trim());
    if (seconds == null || seconds < 0 || seconds > 86400) {
      _interval.text = '${app.phoneGpsIntervalSeconds ?? 900}';
      if (mounted) {
        showAppSnackBar(
          context,
          'Enter a GPS interval between 0 and 86400 seconds',
          replace: false,
        );
      }
      return;
    }
    await app.setPhoneGpsInterval(seconds);
    if (mounted) FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppViewState>();
    final hasNode = app.activeIdentity?.live ?? false;
    final fixAge = app.phoneGpsLastFixAge;
    final interval = app.phoneGpsIntervalSeconds;
    final subtitle = [
      app.phoneBatteryPercent == null
          ? 'Battery unavailable'
          : 'Battery ${app.phoneBatteryPercent}%',
      app.phoneGpsRequested ? 'GPS on' : 'GPS off',
      app.phoneLocationPermissionLabel,
      if (interval != null) 'every ${interval}s',
      if (fixAge != null) 'fix ${fixAge.inSeconds}s old',
    ].join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.phone_android),
                const SizedBox(width: 8),
                Text(
                  'Phone telemetry',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(subtitle),
            if (app.phoneGpsLastError != null)
              Text(
                app.phoneGpsLastError!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Share phone GPS'),
              subtitle: Text(
                app.phoneGpsRequested
                    ? 'Enabled. Contacts still need location permission.'
                    : 'Enable to include phone coordinates in adverts and '
                        'location telemetry.',
              ),
              value: app.phoneGpsRequested,
              onChanged:
                  hasNode ? (value) => app.setPhoneGpsEnabled(value) : null,
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _interval,
                    enabled: hasNode,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'GPS interval (seconds)',
                      helperText: interval == null
                          ? '0-86400; 0 means 1 second'
                          : 'Effective now: ${interval}s',
                    ),
                    onSubmitted: (_) => _saveInterval(),
                  ),
                ),
                IconButton(
                  onPressed: hasNode ? _saveInterval : null,
                  icon: const Icon(Icons.check),
                  tooltip: 'Save GPS interval',
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _requestLocation,
                  child: const Text('Allow location'),
                ),
                TextButton(
                  onPressed: app.openPhoneLocationSettings,
                  child: const Text('System settings'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BackupCard extends StatelessWidget {
  const _BackupCard();

  @override
  Widget build(BuildContext context) {
    return ActionTile(
      icon: Icons.settings_backup_restore,
      title: 'Backup & restore',
      subtitle:
          'Save or restore identities, contacts, channels, messages, and settings',
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const BackupScreen()),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.app, required this.identityLabel});

  final AppViewState app;
  final String identityLabel;

  @override
  Widget build(BuildContext context) {
    final deviceStatus = switch (app.devicePhase) {
      DeviceLinkPhase.connecting => 'connecting',
      DeviceLinkPhase.connected => 'connected',
      DeviceLinkPhase.reconnecting => 'reconnecting',
      DeviceLinkPhase.waiting => 'waiting',
      DeviceLinkPhase.disconnecting => 'disconnecting',
      DeviceLinkPhase.idle => 'disconnected',
    };
    return StatusCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Identity: $identityLabel',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Identities: ${app.identities.length}'
              ' (${app.identities.where((summary) => summary.live).length} live)'),
          Text('Device: $deviceStatus'),
          Text('Proxy: ${app.proxyStatus.name}'
              '${app.proxyStatus == ProxyStatus.running ? ' (port ${app.port})' : ''}'),
        ],
      ),
    );
  }
}
