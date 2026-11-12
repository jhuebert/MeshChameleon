import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_view_state.dart';
import '../services/diagnostics_snapshot.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/app_surfaces.dart';
import '../widgets/content_width.dart';
import '../widgets/info_row.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  Timer? _refreshTimer;
  late final ValueNotifier<DiagnosticsSnapshot> _snapshot;

  @override
  void initState() {
    super.initState();
    _snapshot =
        ValueNotifier(context.read<AppViewState>().diagnosticsSnapshot());
    _startPeriodicRefresh();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _snapshot.dispose();
    super.dispose();
  }

  /// Packet counters change without AppState notifications, so the diagnostics
  /// page deliberately polls a cheap cached snapshot while visible.
  void _startPeriodicRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  void _refresh() {
    if (!mounted) return;
    _snapshot.value = context.read<AppViewState>().diagnosticsSnapshot();
  }

  void _pauseRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  void _resumeRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _refresh();
      _startPeriodicRefresh();
    });
  }

  Future<void> _copyDiagnostics() async {
    final report =
        context.read<AppViewState>().diagnosticsSnapshot().toReport();
    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) return;
    showAppSnackBar(context, 'Diagnostics copied', replace: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Information'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: 'Copy diagnostics',
            onPressed: _copyDiagnostics,
          ),
        ],
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollStartNotification) _pauseRefresh();
          if (notification is ScrollEndNotification) _resumeRefresh();
          return false;
        },
        child: SafeArea(
          child: ContentWidth(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'The copied report includes addresses, names, and recent '
                    'log lines. Review it before sharing.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
                RepaintBoundary(child: _buildCard(_snapshot.value)),
                _liveSection(_statusCard),
                _liveSection(_phoneCard),
                _liveSection(_clientCard),
                _liveSection(_deviceCard),
                _liveSection(_meshCard),
                _liveSection(_identitiesCard),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _liveSection(Widget Function(DiagnosticsSnapshot) builder) =>
      ValueListenableBuilder<DiagnosticsSnapshot>(
        valueListenable: _snapshot,
        builder: (context, snapshot, _) => RepaintBoundary(
          child: builder(snapshot),
        ),
      );

  Widget _buildCard(DiagnosticsSnapshot snapshot) => _SectionCard(
        title: 'Build',
        icon: Icons.info_outline,
        children: [
          for (final entry in snapshot.buildInfo.cardDetails)
            InfoRow(label: entry.key, value: entry.value),
        ],
      );

  Widget _statusCard(DiagnosticsSnapshot snapshot) => _SectionCard(
        title: 'Status',
        icon: Icons.monitor_heart_outlined,
        children: [
          InfoRow(
            label: 'Uptime',
            value: formatDuration(snapshot.appUptime),
          ),
          InfoRow(label: 'Proxy', value: snapshot.proxyLabel),
          InfoRow(label: 'Device', value: snapshot.deviceLabelText),
          InfoRow(
            label: 'Identities',
            value: '${snapshot.identities.length} '
                '(${snapshot.liveIdentityCount} live)',
          ),
          InfoRow(
            label: 'Service',
            value: snapshot.foregroundServiceRunning ? 'Running' : 'Stopped',
          ),
          if (snapshot.identityDatabaseError != null)
            InfoRow(
              label: 'Database',
              value: snapshot.identityDatabaseError!,
            ),
        ],
      );

  Widget _phoneCard(DiagnosticsSnapshot snapshot) => _SectionCard(
        title: 'Phone telemetry',
        icon: Icons.phone_android,
        children: [
          InfoRow(
            label: 'Battery',
            value: snapshot.phoneBatteryPercent == null
                ? 'Unavailable'
                : '${snapshot.phoneBatteryPercent}%',
          ),
          InfoRow(
            label: 'GPS',
            value: snapshot.phoneGpsRequested ? 'Enabled' : 'Disabled',
          ),
          InfoRow(
            label: 'Location permission',
            value: snapshot.phoneLocationPermission,
          ),
          if (snapshot.phoneGpsIntervalSeconds != null)
            InfoRow(
              label: 'Interval',
              value: '${snapshot.phoneGpsIntervalSeconds}s',
            ),
          if (snapshot.phoneGpsLastFixAge != null)
            InfoRow(
              label: 'Last fix',
              value: '${formatDuration(snapshot.phoneGpsLastFixAge!)} ago',
            ),
          InfoRow(
            label: 'Service type',
            value: snapshot.foregroundIncludesLocation
                ? 'Includes location'
                : 'No location type',
          ),
          if (snapshot.phoneGpsLastError != null)
            InfoRow(
              label: 'Last error',
              value: snapshot.phoneGpsLastError!,
            ),
        ],
      );

  Widget _clientCard(DiagnosticsSnapshot snapshot) {
    final metrics = snapshot.companion;
    return _SectionCard(
      title: 'MeshCore app',
      icon: Icons.smartphone,
      children: [
        InfoRow(
          label: 'Status',
          value: metrics.clientConnected ? 'Connected' : 'Not connected',
        ),
        if (metrics.clientConnected) ...[
          InfoRow(
            label: 'Address',
            value: metrics.currentClientAddress ?? 'unknown',
          ),
          InfoRow(
            label: 'Connected for',
            value: formatDuration(metrics.currentClientDuration),
          ),
        ],
        InfoRow(
          label: 'Protocol',
          value: metrics.appTargetVer?.toString() ?? 'unknown',
        ),
        InfoRow(
          label: 'Disconnects',
          value: '${formatCount(metrics.clientDisconnects)} '
              '(${formatCount(metrics.evictions)} evictions, '
              '${formatCount(metrics.idleTimeouts)} idle, '
              '${formatCount(metrics.clientErrors)} errors)',
        ),
        InfoRow(
          label: 'Errors',
          value: '${formatCount(metrics.errorReplyFrames)} replies, '
              '${formatCount(metrics.disabledReplyFrames)} disabled, '
              '${formatCount(metrics.unsupportedCommands)} unsupported',
        ),
        InfoRow(
          label: 'Write errors',
          value: formatCount(metrics.writeErrors),
        ),
        if (metrics.lastDisconnectReason != null)
          InfoRow(
            label: 'Last disconnect',
            value: metrics.lastDisconnectReason!,
          ),
      ],
    );
  }

  Widget _deviceCard(DiagnosticsSnapshot snapshot) {
    final metrics = snapshot.link;
    final radio = snapshot.radioHealth;
    final now = DateTime.now();
    return _SectionCard(
      title: 'Device link',
      icon: Icons.router_outlined,
      children: [
        InfoRow(label: 'Status', value: snapshot.deviceLabelText),
        if (snapshot.deviceInfo != null) ...[
          InfoRow(
            label: 'Firmware',
            value: 'code ${snapshot.deviceInfo!.firmwareVerCode}, '
                    '${snapshot.deviceInfo!.manufacturer} '
                    '${snapshot.deviceInfo!.version}'
                .trim(),
          ),
        ],
        InfoRow(
          label: 'Connection',
          value: '${formatCount(metrics.connectAttempts)} attempts, '
              '${formatCount(metrics.connectSuccesses)} connected, '
              '${formatCount(metrics.unexpectedDrops)} dropped, '
              '${formatCount(snapshot.reconnectSuccesses)} reconnected',
        ),
        if (snapshot.deviceConnected)
          InfoRow(
            label: 'Connected',
            value: formatDuration(metrics.currentSessionDuration),
          ),
        if (radio == null)
          const InfoRow(label: 'Physical radio', value: 'Unavailable')
        else ...[
          InfoRow(
            label: 'Physical radio',
            value: '${radio.volts.toStringAsFixed(2)} V; '
                '${formatCount(radio.storageUsedKb)} of '
                '${formatCount(radio.storageTotalKb)} KiB used; '
                'sampled ${_ageLabel(radio.ageAt(now))} ago',
          ),
        ],
        if (metrics.lastRawRxAt != null)
          InfoRow(
            label: 'Last raw RX',
            value: '${_ageLabel(now.difference(metrics.lastRawRxAt!))} ago',
          ),
        if (metrics.lastError != null)
          InfoRow(label: 'Last error', value: metrics.lastError!),
      ],
    );
  }

  Widget _meshCard(DiagnosticsSnapshot snapshot) {
    final metrics = snapshot.link;
    return _SectionCard(
      title: 'Mesh traffic',
      icon: Icons.cell_tower,
      children: [
        InfoRow(
          label: 'TX / RX',
          value: '${formatCount(metrics.rawTxPackets)} / '
              '${formatCount(metrics.rawRxPackets)} packets',
        ),
        InfoRow(
          label: 'Bytes',
          value: '${formatBytes(metrics.rawTxBytes)} / '
              '${formatBytes(metrics.rawRxBytes)}',
        ),
        InfoRow(
          label: 'TX errors',
          value: formatCount(metrics.rawTxFailures),
        ),
        if (metrics.lastRssi != null)
          InfoRow(
            label: 'Signal',
            value: '${metrics.lastRssi!.round()} dBm, '
                '${metrics.lastSnr?.toStringAsFixed(1) ?? '?'} dB SNR',
          ),
      ],
    );
  }

  Widget _identitiesCard(DiagnosticsSnapshot snapshot) => _SectionCard(
        title: 'Identities',
        icon: Icons.key_outlined,
        children: [
          if (snapshot.identities.isEmpty)
            const Text('No identities.')
          else
            for (final identity in snapshot.identities)
              _IdentityTile(identity: identity),
        ],
      );
}

String _ageLabel(Duration age) {
  if (age.isNegative) age = Duration.zero;
  if (age.inSeconds < 60) return '${age.inSeconds}s';
  if (age.inMinutes < 60) return '${age.inMinutes}m';
  return '${age.inHours}h';
}

class _IdentityTile extends StatelessWidget {
  const _IdentityTile({required this.identity});

  final IdentityDiagnostics identity;

  @override
  Widget build(BuildContext context) {
    final packets = identity.packets;
    final status = !identity.enabled
        ? ' · disabled'
        : identity.live
            ? ' · live'
            : '';
    final subtitle = '#${identity.prefixHex}'
        '${identity.active ? ' · active' : ''}'
        '$status'
        ' · ${identity.contactCount} contacts'
        ' · ${identity.channelCount} channels';
    return ExpansionTile(
      key: PageStorageKey<String>('identity-${identity.id}'),
      initiallyExpanded: identity.active,
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Text(identity.name),
      subtitle: Text(subtitle),
      children: [
        if (packets == null) ...[
          InfoRow(
            label: 'Status',
            value: identity.enabled ? 'Not live' : 'Disabled',
          ),
          if (identity.unavailableReason != null)
            InfoRow(label: 'Reason', value: identity.unavailableReason!),
        ] else ...[
          InfoRow(
            label: 'TX / RX',
            value: '${formatCount(packets.sent)} / '
                '${formatCount(packets.received)}',
          ),
          InfoRow(
            label: 'Flood TX / RX',
            value: '${formatCount(packets.floodTx)} / '
                '${formatCount(packets.floodRx)}',
          ),
          InfoRow(
            label: 'Direct TX / RX',
            value: '${formatCount(packets.directTx)} / '
                '${formatCount(packets.directRx)}',
          ),
          InfoRow(
            label: 'RX errors',
            value: formatCount(packets.receiveErrors),
          ),
          if (packets.lastRssi != 0)
            InfoRow(
              label: 'Signal',
              value: '${packets.lastRssi} dBm, '
                  '${packets.lastSnr.toStringAsFixed(1)} dB SNR, '
                  'noise ${packets.noiseFloor} dBm',
            ),
          InfoRow(
            label: 'Queue',
            value: '${formatCount(packets.queueLength)} messages',
          ),
          InfoRow(
            label: 'Airtime',
            value:
                '${formatDuration(Duration(seconds: packets.txAirSeconds))} / '
                '${formatDuration(Duration(seconds: packets.rxAirSeconds))}',
          ),
          InfoRow(
            label: 'Queued',
            value: '${formatCount(identity.queuedDirect)} direct, '
                '${formatCount(identity.queuedChannel)} channel',
          ),
          if (identity.unavailableReason != null)
            InfoRow(label: 'Reason', value: identity.unavailableReason!),
        ],
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return StatusCard(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}
