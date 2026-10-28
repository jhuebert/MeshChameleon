import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/diagnostics_snapshot.dart';

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
    _snapshot = ValueNotifier(context.read<AppState>().diagnosticsSnapshot());
    _startPeriodicRefresh();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _snapshot.dispose();
    super.dispose();
  }

  void _startPeriodicRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  void _refresh() {
    if (!mounted) return;
    _snapshot.value = context.read<AppState>().diagnosticsSnapshot();
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
    final report = context.read<AppState>().diagnosticsSnapshot().toReport();
    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Diagnostics copied')),
    );
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
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            RepaintBoundary(child: _buildCard(_snapshot.value)),
            _liveSection(_statusCard),
            _liveSection(_clientCard),
            _liveSection(_deviceCard),
            _liveSection(_meshCard),
            _liveSection(_identitiesCard),
          ],
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
            _InfoRow(label: entry.key, value: entry.value),
        ],
      );

  Widget _statusCard(DiagnosticsSnapshot snapshot) => _SectionCard(
        title: 'Status',
        icon: Icons.monitor_heart_outlined,
        children: [
          _InfoRow(
            label: 'Uptime',
            value: formatDuration(snapshot.appUptime),
          ),
          _InfoRow(label: 'Proxy', value: snapshot.proxyLabel),
          _InfoRow(label: 'Device', value: snapshot.deviceLabelText),
          _InfoRow(
            label: 'Identities',
            value: '${snapshot.identities.length} '
                '(${snapshot.liveIdentityCount} live)',
          ),
          _InfoRow(
            label: 'Service',
            value: snapshot.foregroundServiceRunning ? 'Running' : 'Stopped',
          ),
          if (snapshot.identityDatabaseError != null)
            _InfoRow(
              label: 'Database',
              value: snapshot.identityDatabaseError!,
            ),
        ],
      );

  Widget _clientCard(DiagnosticsSnapshot snapshot) {
    final metrics = snapshot.companion;
    return _SectionCard(
      title: 'MeshCore app',
      icon: Icons.smartphone,
      children: [
        _InfoRow(
          label: 'Status',
          value: metrics.clientConnected ? 'Connected' : 'Not connected',
        ),
        if (metrics.clientConnected) ...[
          _InfoRow(
            label: 'Address',
            value: metrics.currentClientAddress ?? 'unknown',
          ),
          _InfoRow(
            label: 'Connected for',
            value: formatDuration(metrics.currentClientDuration),
          ),
        ],
        _InfoRow(
          label: 'Protocol',
          value: metrics.appTargetVer?.toString() ?? 'unknown',
        ),
        _InfoRow(
          label: 'Disconnects',
          value: '${formatCount(metrics.clientDisconnects)} '
              '(${formatCount(metrics.evictions)} evictions, '
              '${formatCount(metrics.idleTimeouts)} idle, '
              '${formatCount(metrics.clientErrors)} errors)',
        ),
        _InfoRow(
          label: 'Errors',
          value: '${formatCount(metrics.errorReplies)} replies, '
              '${formatCount(metrics.unsupportedCommands)} unsupported',
        ),
        _InfoRow(
          label: 'Write errors',
          value: formatCount(metrics.writeErrors),
        ),
        if (metrics.lastDisconnectReason != null)
          _InfoRow(
            label: 'Last disconnect',
            value: metrics.lastDisconnectReason!,
          ),
      ],
    );
  }

  Widget _deviceCard(DiagnosticsSnapshot snapshot) {
    final metrics = snapshot.link;
    return _SectionCard(
      title: 'Device link',
      icon: Icons.router_outlined,
      children: [
        _InfoRow(label: 'Status', value: snapshot.deviceLabelText),
        if (snapshot.deviceInfo != null) ...[
          _InfoRow(
            label: 'Firmware',
            value: 'code ${snapshot.deviceInfo!.firmwareVerCode}, '
                    '${snapshot.deviceInfo!.manufacturer} '
                    '${snapshot.deviceInfo!.version}'
                .trim(),
          ),
        ],
        _InfoRow(
          label: 'Connection',
          value: '${formatCount(metrics.connectAttempts)} attempts, '
              '${formatCount(metrics.connectSuccesses)} connected, '
              '${formatCount(metrics.unexpectedDrops)} dropped, '
              '${formatCount(snapshot.reconnectAttempts)} reconnected',
        ),
        if (snapshot.deviceConnected)
          _InfoRow(
            label: 'Connected',
            value: formatDuration(metrics.currentSessionDuration),
          ),
        if (metrics.lastError != null)
          _InfoRow(label: 'Last error', value: metrics.lastError!),
      ],
    );
  }

  Widget _meshCard(DiagnosticsSnapshot snapshot) {
    final metrics = snapshot.link;
    return _SectionCard(
      title: 'Mesh traffic',
      icon: Icons.cell_tower,
      children: [
        _InfoRow(
          label: 'TX / RX',
          value: '${formatCount(metrics.rawTxPackets)} / '
              '${formatCount(metrics.rawRxPackets)} packets',
        ),
        _InfoRow(
          label: 'Bytes',
          value: '${formatBytes(metrics.rawTxBytes)} / '
              '${formatBytes(metrics.rawRxBytes)}',
        ),
        _InfoRow(
          label: 'TX errors',
          value: formatCount(metrics.rawTxFailures),
        ),
        if (metrics.lastRssi != null)
          _InfoRow(
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
          _InfoRow(
            label: 'Status',
            value: identity.enabled ? 'Not live' : 'Disabled',
          ),
          if (identity.unavailableReason != null)
            _InfoRow(label: 'Reason', value: identity.unavailableReason!),
        ] else ...[
          _InfoRow(
            label: 'TX / RX',
            value: '${formatCount(packets.sent)} / '
                '${formatCount(packets.received)}',
          ),
          _InfoRow(
            label: 'Flood TX / RX',
            value: '${formatCount(packets.floodTx)} / '
                '${formatCount(packets.floodRx)}',
          ),
          _InfoRow(
            label: 'Direct TX / RX',
            value: '${formatCount(packets.directTx)} / '
                '${formatCount(packets.directRx)}',
          ),
          _InfoRow(
            label: 'RX errors',
            value: formatCount(packets.receiveErrors),
          ),
          _InfoRow(
            label: 'Queue',
            value: '${formatCount(packets.queueLength)} messages',
          ),
          _InfoRow(
            label: 'Airtime',
            value:
                '${formatDuration(Duration(seconds: packets.txAirSeconds))} / '
                '${formatDuration(Duration(seconds: packets.rxAirSeconds))}',
          ),
          _InfoRow(
            label: 'Queued',
            value: '${formatCount(identity.queuedDirect)} direct, '
                '${formatCount(identity.queuedChannel)} channel',
          ),
          if (identity.unavailableReason != null)
            _InfoRow(label: 'Reason', value: identity.unavailableReason!),
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
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
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
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
