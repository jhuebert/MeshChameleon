import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_view_state.dart';
import '../widgets/content_width.dart';
import '../widgets/info_row.dart';
import '../widgets/numeric_edit_dialog.dart';
import 'about_screen.dart';
import 'backup_screen.dart';
import 'diagnostics_screen.dart';
import 'identities_screen.dart';
import 'log_screen.dart';

/// Compact, grouped preferences. Infrequent actions stay here; frequent
/// actions (switching identity, connecting) stay on Home.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  String? _gpsFailureIdentity;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) _refresh();
  }

  /// Battery status and permission/GPS status change out of band; re-read
  /// them on entry and on foreground return. No permission prompts here.
  void _refresh() {
    final app = context.read<AppViewState>();
    app.refreshBatteryOptimizationStatus();
    app.refreshPhoneTelemetry();
  }

  Future<void> _editPort() async {
    final app = context.read<AppViewState>();
    await showNumericEditDialog(
      context,
      title: 'Proxy server port',
      label: 'Port',
      initialValue: app.port,
      min: 1,
      max: 65535,
      saveLabel: 'Save port',
      helperText: 'Clients connect to this TCP port',
      stillEligible: () {
        final current = context.read<AppViewState>();
        return current.proxyStatus != ProxyStatus.running && !current.busy;
      },
      ineligibleMessage:
          'Stop the proxy and wait for the current operation first.',
      onSave: app.setProxyPort,
      failureMessage: 'Could not save the port. Try again.',
    );
  }

  Future<void> _editGpsInterval() async {
    final app = context.read<AppViewState>();
    final scope = app.activeGpsScope;
    if (scope == null) return;
    await showNumericEditDialog(
      context,
      title: 'GPS interval',
      label: 'Interval (seconds)',
      initialValue: scope.configuredIntervalSeconds,
      min: 0,
      max: GpsScope.maxIntervalSeconds,
      saveLabel: 'Save GPS interval',
      helperText: '0 requests a 1-second effective interval (battery-heavy)',
      stillEligible: () {
        final current = context.read<AppViewState>();
        return !current.busy &&
            current.activeGpsScope?.identityId == scope.identityId;
      },
      ineligibleMessage:
          'The active identity changed or is busy. Re-open the editor to try again.',
      onSave: app.setPhoneGpsInterval,
      failureMessage: 'Could not save the GPS interval. Try again.',
    );
  }

  Future<void> _toggleGps(bool enabled) async {
    final app = context.read<AppViewState>();
    final id = app.activeGpsScope?.identityId;
    setState(() => _gpsFailureIdentity = null);
    final ok = await app.setPhoneGpsEnabled(enabled);
    if (!ok && mounted) {
      setState(() => _gpsFailureIdentity = id);
    }
  }

  Future<void> _requestLocation() async {
    final app = context.read<AppViewState>();
    final identityId = app.activeIdentity?.id;
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
    if (proceed == true && mounted && app.activeIdentity?.id == identityId) {
      await app.requestPhoneLocationPermission();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppViewState>();
    final scope = app.activeGpsScope;
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ContentWidth(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              const _SectionLabel('Connection & background'),
              _Group(
                children: [
                  ListTile(
                    leading: const Icon(Icons.settings_ethernet),
                    title: const Text('Proxy server port'),
                    subtitle: Text(
                      app.proxyStatus == ProxyStatus.running
                          ? '${app.port} · Stop the proxy to change'
                          : '${app.port}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: app.busy ? null : _editPort,
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.restart_alt),
                    title: const Text('Resume on launch'),
                    subtitle: Text(app.lastSession == null
                        ? 'Resume on app launch, not reboot. '
                            'Connect a radio first.'
                        : 'Reconnect radio and proxy on app launch, not reboot.'),
                    value: app.autoResume,
                    onChanged:
                        app.busy ? null : (value) => app.setAutoResume(value),
                  ),
                  if (isAndroid)
                    _BatteryOptimizationTile(
                      ignored: app.batteryOptimizationsIgnored,
                      onOpenSettings: app.openBatteryOptimizationSettings,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const _SectionLabel('Phone telemetry'),
              Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.phone_android),
                      title: Text(
                        scope == null
                            ? 'Active identity'
                            : 'For ${scope.identityName}',
                      ),
                      subtitle: Text(
                        scope == null
                            ? 'Connect a radio to edit GPS settings.'
                            : '#${app.activeIdentity?.prefixHex ?? ''} · '
                                'this identity’s own settings',
                      ),
                    ),
                    SwitchListTile(
                      secondary: const Icon(Icons.gps_fixed),
                      title: const Text('Use phone GPS'),
                      subtitle: Text(
                        scope == null
                            ? 'Unavailable while this identity is offline.'
                            : scope.requested
                                ? 'Use coordinates for this identity.'
                                : 'Other identities may still use GPS.',
                      ),
                      value: scope?.requested ?? false,
                      onChanged: scope == null || app.busy ? null : _toggleGps,
                    ),
                    if (scope != null &&
                        _gpsFailureIdentity == scope.identityId)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'Could not change phone GPS. Try again.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ListTile(
                      leading: const Icon(Icons.timer_outlined),
                      title: const Text('GPS interval'),
                      subtitle: Text(
                        scope == null
                            ? 'Unavailable — identity is not live'
                            : 'Every ${scope.effectiveIntervalSeconds} s'
                                '${scope.configuredIntervalSeconds == 0 ? ' (stored 0)' : ''}',
                      ),
                      trailing: TextButton(
                        onPressed:
                            scope == null || app.busy ? null : _editGpsInterval,
                        child: const Text('Edit'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Shared phone status',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 4),
                      InfoRow(
                        label: 'Phone battery',
                        value: app.phoneBatteryPercent == null
                            ? 'Unavailable'
                            : '${app.phoneBatteryPercent}%',
                      ),
                      InfoRow(
                        label: 'Location permission',
                        value: app.phoneLocationPermissionLabel,
                      ),
                      InfoRow(
                        label: 'GPS demand',
                        value: app.phoneGpsRequested
                            ? 'At least one identity requests GPS'
                            : 'No identity requests GPS',
                      ),
                      InfoRow(
                        label: 'Effective cadence',
                        value: app.phoneGpsIntervalSeconds == null
                            ? 'Not sampling'
                            : 'Every ${app.phoneGpsIntervalSeconds} s',
                      ),
                      InfoRow(
                        label: 'Last fix',
                        value: app.phoneGpsLastFixAge == null
                            ? 'No fix yet'
                            : '${app.phoneGpsLastFixAge!.inSeconds}s ago',
                      ),
                      if (app.phoneGpsLastError != null)
                        InfoRow(
                          label: 'Last error',
                          value: app.phoneGpsLastError!,
                        ),
                      const SizedBox(height: 8),
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
              ),
              const SizedBox(height: 8),
              const _Footnote(
                'Telemetry permissions and advert settings govern location '
                'sharing. Turning GPS off does not erase saved coordinates.',
              ),
              const SizedBox(height: 16),
              const _SectionLabel('Data'),
              _Group(
                children: [
                  ListTile(
                    leading: const Icon(Icons.key),
                    title: const Text('Identities'),
                    subtitle: Text(
                      '${app.identities.length} '
                      '${app.identities.length == 1 ? 'identity' : 'identities'}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _push(context, const IdentitiesScreen()),
                  ),
                  ListTile(
                    leading: const Icon(Icons.settings_backup_restore),
                    title: const Text('Backup & restore'),
                    subtitle: const Text(
                      'All identities and their keys in one '
                      'passphrase-encrypted file',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _push(context, const BackupScreen()),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const _SectionLabel('Support'),
              _Group(
                children: [
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('Information'),
                    subtitle: const Text('Live status and diagnostics'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _push(context, const DiagnosticsScreen()),
                  ),
                  ListTile(
                    leading: const Icon(Icons.receipt_long),
                    title: const Text('Log'),
                    subtitle: const Text('Recent app and radio events'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _push(context, const LogScreen()),
                  ),
                  ListTile(
                    leading: const Icon(Icons.apps),
                    title: const Text('About MeshChameleon'),
                    subtitle: const Text('Version and open-source licenses'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _push(context, const AboutScreen()),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _push(BuildContext context, Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
}

class _BatteryOptimizationTile extends StatelessWidget {
  const _BatteryOptimizationTile({
    required this.ignored,
    required this.onOpenSettings,
  });

  final bool? ignored;
  final Future<void> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final value = ignored;
    return ListTile(
      leading: Icon(
        value == true ? Icons.battery_saver : Icons.battery_alert,
      ),
      title: const Text('Battery optimization'),
      subtitle: Text(
        value == null
            ? 'Checking…'
            : value
                ? 'Unrestricted · Other background limits may still apply'
                : 'Optimized · May interrupt the background link',
      ),
      trailing: value == false
          ? TextButton(
              onPressed: () => unawaited(onOpenSettings()),
              child: const Text('Open settings'),
            )
          : null,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 16),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _Footnote extends StatelessWidget {
  const _Footnote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}
