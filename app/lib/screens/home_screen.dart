import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_route_observer.dart';
import '../app_view_state.dart';
import '../services/diagnostics_snapshot.dart';
import '../services/identity_presentation.dart';
import '../theme/app_theme.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/app_surfaces.dart';
import '../widgets/content_width.dart';
import '../widgets/device_target_icon.dart';
import '../widgets/identity_avatar.dart';
import '../widgets/info_row.dart';
import '../widgets/simulation_badge.dart';
import 'connect_screen.dart';
import 'diagnostics_screen.dart';
import 'identities_screen.dart';
import 'log_screen.dart';
import 'settings_screen.dart';
import 'switch_identity_sheet.dart';

/// Companion control panel: identity and connection controls first, compact
/// activity after them.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, RouteAware {
  static const Duration sampleInterval = Duration(seconds: 5);

  Timer? _sampler;
  late final ValueNotifier<_HomeSnapshot> _snapshot;
  AppViewState? _app;
  bool _resumed = true;
  bool _expanded = false;
  bool _proxyPending = false;
  String? _proxyFailure;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _snapshot =
        ValueNotifier(_HomeSnapshot.fromApp(context.read<AppViewState>()));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppViewState>().refreshBatteryOptimizationStatus();
        _startSampling(immediate: true);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.read<AppViewState>();
    if (!identical(_app, app)) {
      _app?.removeListener(_onAppChanged);
      _app = app..addListener(_onAppChanged);
    }
    final route = ModalRoute.of(context);
    if (route != null) appRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _app?.removeListener(_onAppChanged);
    _sampler?.cancel();
    _snapshot.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _resumed = true;
      context.read<AppViewState>().rearmAfterLinkLoss();
      context.read<AppViewState>().refreshBatteryOptimizationStatus();
      _startSampling(immediate: true);
    } else {
      _resumed = false;
      _pauseSampling();
    }
  }

  @override
  void didPushNext() => _pauseSampling();

  @override
  void didPopNext() => _startSampling(immediate: true);

  void _startSampling({required bool immediate}) {
    _sampler?.cancel();
    if (!_resumed || ModalRoute.of(context)?.isCurrent != true) return;
    if (immediate) _tick();
    _sampler = Timer.periodic(sampleInterval, (_) => _tick());
  }

  void _pauseSampling() {
    _sampler?.cancel();
    _sampler = null;
  }

  /// One cheap, cached snapshot per tick. No radio I/O happens here.
  void _tick() {
    if (!mounted) return;
    _snapshot.value = _HomeSnapshot.fromApp(context.read<AppViewState>());
  }

  void _onAppChanged() {
    if (_resumed && ModalRoute.of(context)?.isCurrent == true) _tick();
  }

  Future<void> _toggleProxy(bool value) async {
    if (_proxyPending) return;
    final app = context.read<AppViewState>();
    setState(() {
      _proxyPending = true;
      _proxyFailure = null;
    });
    try {
      if (value) {
        await app.startProxy();
      } else {
        await app.stopProxy();
      }
    } catch (_) {
      // Reconcile against actual listener state below.
    }
    if (!mounted) return;
    final failed = value &&
        app.proxyStatus != ProxyStatus.running &&
        app.deviceConnected &&
        !app.deviceReconnecting &&
        !app.deviceWaiting;
    setState(() {
      _proxyPending = false;
      _proxyFailure =
          failed ? 'Could not start the proxy. See the log for details.' : null;
    });
  }

  Future<void> _copyEndpoint() async {
    final app = context.read<AppViewState>();
    await Clipboard.setData(ClipboardData(text: '127.0.0.1:${app.port}'));
    if (mounted) {
      showAppSnackBar(context, 'Endpoint copied', replace: false);
    }
  }

  Future<void> _switchIdentity() async {
    final outcome = await showSwitchIdentitySheet(context);
    if (!mounted) return;
    if (outcome == SwitchIdentityOutcome.manage) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const IdentitiesScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppViewState>();
    final showBatteryAdvice = defaultTargetPlatform == TargetPlatform.android &&
        (app.deviceConnected || app.deviceReconnecting || app.deviceWaiting) &&
        app.batteryOptimizationsIgnored == false;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset(
              'assets/branding/icon.png',
              width: 30,
              height: 30,
              semanticLabel: 'MeshChameleon icon',
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'MeshChameleon',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ContentWidth(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              _IdentitySection(
                app: app,
                onSwitch: _switchIdentity,
                onManage: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const IdentitiesScreen()),
                ),
              ),
              if (showBatteryAdvice) ...[
                const SizedBox(height: 12),
                _BatteryAdviceBanner(
                  onOpenSettings: app.openBatteryOptimizationSettings,
                ),
              ],
              const SizedBox(height: 12),
              _ConnectionsSection(
                app: app,
                snapshotListenable: _snapshot,
                proxyPending: _proxyPending,
                proxyFailure: _proxyFailure,
                onToggleProxy: _toggleProxy,
                onRetryProxy: () => _toggleProxy(true),
                onCopyEndpoint: _copyEndpoint,
                onViewLog: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LogScreen()),
                ),
              ),
              const SizedBox(height: 12),
              _ActivitySection(
                snapshotListenable: _snapshot,
                app: app,
                expanded: _expanded,
                onToggleExpanded: () => setState(() => _expanded = !_expanded),
                onOpenInformation: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DiagnosticsScreen()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _transportLabel(DeviceTargetKind? kind) => switch (kind) {
      DeviceTargetKind.ble => 'Bluetooth',
      DeviceTargetKind.tcp => 'Wi-Fi/Ethernet',
      DeviceTargetKind.simulated => 'Simulated',
      null => 'Radio',
    };

String _deviceSubtitle(AppViewState app) {
  final label = app.deviceLabel;
  final transport = _transportLabel(app.lastSession?.kind);
  return switch (app.devicePhase) {
    DeviceLinkPhase.connecting => '$transport · Connecting…',
    DeviceLinkPhase.reconnecting => '$transport · Reconnecting…',
    DeviceLinkPhase.waiting => label == null
        ? '$transport · Waiting for companion'
        : '$transport · Waiting for $label',
    DeviceLinkPhase.connected => label == null
        ? '$transport · Connected'
        : '$transport · $label · Connected',
    DeviceLinkPhase.disconnecting => '$transport · Disconnecting…',
    DeviceLinkPhase.idle => 'Not connected',
  };
}

String _proxyDisabledReason(AppViewState app, bool pending) {
  if (pending) return 'Please wait…';
  if (app.deviceWaiting) return 'Waiting for the radio';
  if (app.deviceConnecting || app.deviceReconnecting) {
    return 'Waiting for the connection';
  }
  if (app.busy) return 'Wait for the current operation to finish';
  if (app.identityDatabaseError != null) {
    return 'Resolve the identity problem first';
  }
  if (app.deviceConnected && (app.activeIdentity?.live != true)) {
    return 'The active identity is unavailable';
  }
  return 'Connect a radio to start the proxy';
}

/// Home owns copies of the metrics, not the mutable diagnostic counters.
class _HomeSnapshot {
  const _HomeSnapshot({
    required this.clientConnected,
    required this.clientAddress,
    required this.txPackets,
    required this.rxPackets,
    required this.rssi,
    required this.snr,
    required this.receivedAt,
    required this.radioHealth,
  });

  factory _HomeSnapshot.fromApp(AppViewState app) {
    final snapshot = app.diagnosticsSnapshot();
    final link = snapshot.link;
    final currentRx = app.deviceConnected && link.rxObservedThisSession;
    return _HomeSnapshot(
      clientConnected: snapshot.companion.clientConnected,
      clientAddress: snapshot.companion.currentClientAddress,
      txPackets: link.rawTxPackets,
      rxPackets: link.rawRxPackets,
      rssi: currentRx ? link.currentRssi : null,
      snr: currentRx ? link.currentSnr : null,
      receivedAt: currentRx ? link.currentRawRxAt : null,
      radioHealth: app.deviceConnected ? snapshot.radioHealth : null,
    );
  }

  final bool clientConnected;
  final String? clientAddress;
  final int txPackets;
  final int rxPackets;
  final double? rssi;
  final double? snr;
  final DateTime? receivedAt;
  final RadioHealth? radioHealth;
}

class _IdentitySection extends StatelessWidget {
  const _IdentitySection({
    required this.app,
    required this.onSwitch,
    required this.onManage,
  });

  final AppViewState app;
  final VoidCallback onSwitch;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = app.identityDatabaseError;
    if (error != null) {
      return ErrorBanner(
        title: 'Identity database unavailable',
        message: '$error\nYour data was kept. Retry, or restore from a '
            'backup in Settings.',
        actionLabel: 'Retry',
        onAction: app.busy ? null : () => app.loadIdentities(),
      );
    }
    if (!app.identitiesLoaded) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 16),
              Text('Loading identities…'),
            ],
          ),
        ),
      );
    }
    final identities = app.identities;
    if (identities.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Text(
                'No identities yet',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Create your first identity to get started.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: app.busy ? null : onManage,
                icon: const Icon(Icons.add),
                label: const Text('Create identity'),
              ),
            ],
          ),
        ),
      );
    }

    final active = app.activeIdentity;
    if (active == null) {
      // Identities exist but none is selected; offer the picker.
      return _identityCard(
        context,
        avatarName: 'MeshChameleon',
        title: 'No identity selected',
        subtitle: 'Choose which identity the MeshCore app uses.',
        semanticLabel: 'Choose an identity',
        onTap: onSwitch,
      );
    }

    final reason = identityDisabledReason(active);
    final queue = active.queuedDirect + active.queuedChannel;
    final othersWaiting = otherIdentitiesWaiting(identities, active.id);

    if (reason != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IdentityAvatar(name: active.name),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          active.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge,
                        ),
                        Text(
                          '#${active.prefixHex} · $reason',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'This identity cannot start a proxy session until its key '
                'and state are available. The proxy stays off against it.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: onManage,
                    child: const Text('Manage identities'),
                  ),
                  OutlinedButton(
                    onPressed: onSwitch,
                    child: const Text('Switch identity'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Semantics(
        button: true,
        label: 'Switch identity. ${active.name}, '
            '#${active.prefixHex}, '
            '${identityAvailabilityLabel(active)}. '
            '${active.contactCount} contacts, '
            '${active.channelCount} channels, '
            '${waitingToSyncLabel(queue)}.',
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onSwitch,
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IdentityAvatar(name: active.name),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              active.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleLarge,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '#${active.prefixHex} · '
                              '${identityAvailabilityLabel(active)}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Switch',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Icon(
                            Icons.keyboard_arrow_down,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${active.contactCount} contacts · '
                    '${active.channelCount} channels',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Tooltip(
                    message: 'Direct and channel messages waiting to sync with '
                        'this identity — not unread or unsent messages. '
                        'They clear when the MeshCore app receives them.',
                    child: Text(
                      waitingToSyncLabel(queue),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (othersWaiting > 0)
                    Text(
                      '$othersWaiting waiting on other identities',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _identityCard(
    BuildContext context, {
    required String avatarName,
    required String title,
    required String subtitle,
    required String semanticLabel,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Card(
      child: Semantics(
        button: true,
        label: semanticLabel,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  IdentityAvatar(name: avatarName),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.titleLarge),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BatteryAdviceBanner extends StatelessWidget {
  const _BatteryAdviceBanner({required this.onOpenSettings});

  final Future<void> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final status = StatusColors.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: status.attentionContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.battery_alert, color: status.onAttentionContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Background link may be interrupted. Android can throttle the '
              'proxy; setting MeshChameleon to Unrestricted reduces one '
              'source of interruption.',
              style: TextStyle(color: status.onAttentionContainer),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => onOpenSettings(),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
  }
}

class _ConnectionsSection extends StatelessWidget {
  const _ConnectionsSection({
    required this.app,
    required this.snapshotListenable,
    required this.proxyPending,
    required this.proxyFailure,
    required this.onToggleProxy,
    required this.onRetryProxy,
    required this.onCopyEndpoint,
    required this.onViewLog,
  });

  final AppViewState app;
  final ValueListenable<_HomeSnapshot> snapshotListenable;
  final bool proxyPending;
  final String? proxyFailure;
  final ValueChanged<bool> onToggleProxy;
  final VoidCallback onRetryProxy;
  final VoidCallback onCopyEndpoint;
  final VoidCallback onViewLog;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final simulated = app.lastSession?.kind == DeviceTargetKind.simulated &&
        app.deviceConnected;
    final proxyRunning = app.proxyStatus == ProxyStatus.running;
    final canToggleProxy = !app.busy &&
        !proxyPending &&
        (proxyRunning ||
            (app.deviceConnected &&
                app.identityDatabaseError == null &&
                app.activeIdentity?.live == true));
    final disabledReason = _proxyDisabledReason(app, proxyPending);

    return Card(
      child: Column(
        children: [
          _DeviceLinkRow(app: app, simulated: simulated),
          const Divider(height: 1, indent: 16),
          SwitchListTile(
            secondary: const Icon(Icons.dns),
            title: const Text('Proxy server'),
            subtitle: Text(
              proxyPending
                  ? (proxyRunning ? 'Stopping…' : 'Starting…')
                  : proxyRunning
                      ? 'Listening on port ${app.port}'
                      : 'Stopped${canToggleProxy ? '' : ' · $disabledReason'}',
            ),
            value: proxyRunning,
            onChanged: canToggleProxy ? onToggleProxy : null,
          ),
          if (proxyFailure != null) ...[
            const Divider(height: 1, indent: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Icon(Icons.error_outline,
                      size: 20, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      proxyFailure!,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                      onPressed: onRetryProxy, child: const Text('Retry')),
                  TextButton(
                      onPressed: onViewLog, child: const Text('View log')),
                ],
              ),
            ),
          ],
          const Divider(height: 1, indent: 16),
          ValueListenableBuilder<_HomeSnapshot>(
            valueListenable: snapshotListenable,
            builder: (context, snapshot, _) => _ClientRow(
              app: app,
              proxyRunning: proxyRunning,
              snapshot: snapshot,
              onCopyEndpoint: onCopyEndpoint,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceLinkRow extends StatelessWidget {
  const _DeviceLinkRow({required this.app, required this.simulated});

  final AppViewState app;
  final bool simulated;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = app.deviceConnected;
    final actionable = connected ||
        app.deviceConnecting ||
        app.deviceReconnecting ||
        app.deviceWaiting;

    Widget trailing;
    if (app.deviceConnecting || app.deviceReconnecting || app.deviceWaiting) {
      // Recovery stays cancellable even while the socket is still open.
      trailing = TextButton(
        onPressed: app.cancelDeviceAttempt,
        child: const Text('Cancel'),
      );
    } else if (connected) {
      trailing = TextButton(
        onPressed: app.busy ? null : app.disconnectDevice,
        child: const Text('Disconnect'),
      );
    } else if (app.devicePhase == DeviceLinkPhase.disconnecting) {
      trailing = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else {
      trailing = const Icon(Icons.chevron_right);
    }

    final navigation = InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ConnectScreen()),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(deviceTargetIcon(app.lastSession?.kind)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Device link', style: theme.textTheme.titleSmall),
                  Text(_deviceSubtitle(app), style: theme.textTheme.bodyMedium),
                  if (simulated) const SimulationBadge(),
                ],
              ),
            ),
            if (!actionable && app.devicePhase != DeviceLinkPhase.disconnecting)
              const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (MediaQuery.textScalerOf(context).scale(1) > 1.3 ||
            constraints.maxWidth < 280) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              navigation,
              if (actionable ||
                  app.devicePhase == DeviceLinkPhase.disconnecting)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: trailing,
                  ),
                ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: navigation),
            if (actionable || app.devicePhase == DeviceLinkPhase.disconnecting)
              Padding(
                  padding: const EdgeInsets.only(right: 8), child: trailing),
          ],
        );
      },
    );
  }
}

class _ClientRow extends StatelessWidget {
  const _ClientRow({
    required this.app,
    required this.proxyRunning,
    required this.snapshot,
    required this.onCopyEndpoint,
  });

  final AppViewState app;
  final bool proxyRunning;
  final _HomeSnapshot snapshot;
  final VoidCallback onCopyEndpoint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clientConnected = proxyRunning && snapshot.clientConnected;
    final statusText = !proxyRunning
        ? 'Server stopped'
        : clientConnected
            ? 'Connected'
            : 'Waiting for app';
    final clientAddress = clientConnected ? snapshot.clientAddress : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                clientConnected ? Icons.smartphone : Icons.smartphone_outlined,
                color: clientConnected ? theme.colorScheme.primary : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'MeshCore app',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  statusText,
                  textAlign: TextAlign.end,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: clientConnected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          if (clientAddress != null) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 36),
              child: SelectableText(
                'Client address: $clientAddress',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          Row(
            children: [
              const SizedBox(width: 36),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('On this phone', style: theme.textTheme.bodySmall),
                    SelectableText(
                      '127.0.0.1:${app.port}',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Copy endpoint',
                onPressed: onCopyEndpoint,
                icon: const Icon(Icons.copy_outlined),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActivitySection extends StatelessWidget {
  const _ActivitySection({
    required this.snapshotListenable,
    required this.app,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onOpenInformation,
  });

  /// Immutable per-tick diagnostic values; rebuilt only by the sampler.
  final ValueListenable<_HomeSnapshot> snapshotListenable;
  final AppViewState app;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final VoidCallback onOpenInformation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          label: expanded
              ? 'Radio activity, collapse details'
              : 'Radio activity, expand details',
          child: InkWell(
            onTap: onToggleExpanded,
            borderRadius: BorderRadius.circular(8),
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: LayoutBuilder(
                  builder: (context, constraints) => Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Radio activity',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      if (constraints.maxWidth >= 380)
                        Text(
                          expanded ? 'Hide details' : 'Show details',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<_HomeSnapshot>(
          valueListenable: snapshotListenable,
          builder: (context, snapshot, _) => _ActivityCard(
            snapshot: snapshot,
            app: app,
            expanded: expanded,
            onOpenInformation: onOpenInformation,
          ),
        ),
      ],
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.snapshot,
    required this.app,
    required this.expanded,
    required this.onOpenInformation,
  });

  final _HomeSnapshot snapshot;
  final AppViewState app;
  final bool expanded;
  final VoidCallback onOpenInformation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final stackStats = textScale > 1.3;
    final radio = snapshot.radioHealth;
    final now = DateTime.now();
    final signal = snapshot.rssi == null
        ? null
        : '${snapshot.rssi!.round()} dBm · '
            '${snapshot.snr?.toStringAsFixed(1) ?? '?'} dB SNR';
    final lastRxAge = snapshot.receivedAt == null
        ? null
        : _ageLabel(now.difference(snapshot.receivedAt!));
    final sampleAge = radio == null ? null : _ageLabel(radio.ageAt(now));
    // UI-only delayed-sample policy: two normal refresh intervals (120 s).
    // Protocol freshness (node.batteryStale, 10 s) is unaffected.
    final sampleStale =
        radio != null && radio.ageAt(now) > const Duration(seconds: 120);

    final stats = <Widget>[
      _StatCell(
        value: formatCount(snapshot.txPackets),
        label: 'TX packets',
      ),
      _StatCell(
        value: formatCount(snapshot.rxPackets),
        label: 'RX packets',
      ),
      _StatCell(
        value: radio == null ? '—' : '${radio.volts.toStringAsFixed(2)} V',
        label: 'Radio battery',
      ),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (stackStats)
              for (final stat in stats) stat
            else
              Row(
                children: [
                  for (final stat in stats) Expanded(child: stat),
                ],
              ),
            if (!app.deviceConnected)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'No radio connected',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (expanded) ...[
              const Divider(height: 24),
              Text(
                'Details',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              InfoRow(
                label: 'Last mesh RX',
                value: signal ?? 'Not received yet',
              ),
              InfoRow(
                label: 'Reception age',
                value: lastRxAge == null
                    ? 'Not received yet'
                    : 'Last packet $lastRxAge ago',
              ),
              InfoRow(
                label: sampleStale ? 'Radio sample (stale)' : 'Radio sample',
                value: sampleAge == null
                    ? 'Unavailable'
                    : sampleStale
                        ? 'Updated $sampleAge ago — radio may be unreachable'
                        : 'Updated $sampleAge ago',
              ),
              if (radio != null)
                InfoRow(
                  label: 'Radio storage',
                  value: _storageLabel(radio),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onOpenInformation,
                  icon: const Icon(Icons.info_outline, size: 18),
                  label: const Text('Open Information'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _storageLabel(RadioHealth radio) {
    final percent = radio.storageUsedPercent;
    if (percent == null) return 'Unavailable';
    final base = '${formatCount(radio.storageUsedKb)} of '
        '${formatCount(radio.storageTotalKb)} KiB';
    return '$base (${percent.round()}%)';
  }

  String _ageLabel(Duration age) {
    if (age.isNegative) age = Duration.zero;
    if (age.inSeconds < 60) return '${age.inSeconds}s';
    if (age.inMinutes < 60) return '${age.inMinutes}m';
    return '${age.inHours}h';
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
