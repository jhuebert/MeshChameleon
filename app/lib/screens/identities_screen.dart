import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:provider/provider.dart';

import '../app_view_state.dart';
import '../services/identity_presentation.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/app_surfaces.dart';
import '../widgets/content_width.dart';
import '../widgets/identity_avatar.dart';

class IdentitiesScreen extends StatefulWidget {
  const IdentitiesScreen({super.key});

  @override
  State<IdentitiesScreen> createState() => _IdentitiesScreenState();
}

class _IdentitiesScreenState extends State<IdentitiesScreen> {
  Future<void> _activate(IdentitySummary summary) async {
    final app = context.read<AppViewState>();
    if (app.busy || summary.active) return;
    if (!summary.enabled) {
      _snack('Enable ${summary.name} before activating it');
      return;
    }
    if (!summary.canActivate) return;
    final ok = await app.activateIdentity(summary.id);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      _snack('Could not activate ${summary.name}');
    }
  }

  Future<void> _setEnabled(IdentitySummary summary, bool enabled) async {
    final app = context.read<AppViewState>();
    if (app.busy || summary.enabled == enabled) return;
    final ok = await app.setIdentityEnabled(summary.id, enabled);
    if (!mounted) return;
    if (!ok) {
      _snack('Could not ${enabled ? 'enable' : 'disable'} ${summary.name}');
    }
  }

  Future<void> _create() async {
    final app = context.read<AppViewState>();
    if (app.busy || app.identityDatabaseError != null) return;
    final String suggestion;
    try {
      suggestion = await app.suggestIdentityName();
    } catch (_) {
      if (mounted) _snack('Could not read the identity database');
      return;
    }
    if (!mounted) return;
    final name = await _askForName(suggestion);
    if (name == null || !mounted) return;
    final record = await app.createIdentity(name: name);
    if (!mounted) return;
    _snack(record == null
        ? 'Could not create the identity'
        : 'Created ${record.name} (inactive)');
  }

  Future<String?> _askForName(String suggestion) => showDialog<String>(
        context: context,
        builder: (_) => _NewIdentityDialog(suggestion: suggestion),
      );

  Future<void> _clear(IdentitySummary summary) async {
    final app = context.read<AppViewState>();
    if (app.busy) return;
    final confirmed = await _confirm(
      title: 'Clear local data?',
      detail: '${summary.name} (#${summary.prefixHex})\n\n'
          'Contacts, channels, queued messages, advert paths, and preferences '
          'will be cleared. The identity key and current name remain.'
          '${summary.active ? ' The MeshCore app will reconnect.' : ''}',
      action: 'Clear',
    );
    if (!confirmed || !mounted) return;
    final ok = await app.clearLocalData(summary.id);
    if (!mounted) return;
    _snack(ok
        ? 'Cleared local data for ${summary.name}'
        : 'Could not clear local data');
  }

  Future<void> _delete(IdentitySummary summary) async {
    final app = context.read<AppViewState>();
    if (app.busy || summary.active) return;
    final confirmed = await _confirm(
      title: 'Delete identity?',
      detail: '${summary.name} (#${summary.prefixHex})\n\n'
          'The identity key, contacts, channels, and messages are permanently '
          'removed. This cannot be undone.',
      action: 'Delete',
    );
    if (!confirmed || !mounted) return;
    final ok = await app.deleteIdentity(summary.id);
    if (!mounted) return;
    _snack(ok ? 'Deleted ${summary.name}' : 'Could not delete ${summary.name}');
  }

  Future<bool> _confirm({
    required String title,
    required String detail,
    required String action,
  }) =>
      showConfirmDialog(
        context,
        title: title,
        message: detail,
        confirmLabel: action,
        destructive: true,
      );

  void _snack(String message) =>
      showAppSnackBar(context, message, replace: false);

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppViewState>();
    final error = app.identityDatabaseError;
    if (error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Identities')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ErrorBanner(
              title: 'Identity database unavailable',
              message: error,
              actionLabel: 'Retry',
              onAction: app.busy ? null : app.loadIdentities,
            ),
          ),
        ),
      );
    }
    if (!app.identitiesLoaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('Identities')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final identities = app.identities;
    return Scaffold(
      appBar: AppBar(title: const Text('Identities')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: app.busy ? null : _create,
        icon: const Icon(Icons.add),
        label: const Text('Create identity'),
      ),
      body: Column(
        children: [
          if (app.busy) const BusyStrip(padding: EdgeInsets.zero),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'The active identity is the one the MeshCore app uses. '
                    'Switching disconnects the app; reconnect it if it does '
                    'not reconnect automatically.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: identities.isEmpty
                ? _EmptyState(onCreate: app.busy ? null : _create)
                : ContentWidth(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                      itemCount: identities.length,
                      itemBuilder: (context, index) {
                        final summary = identities[index];
                        return _IdentityCard(
                          summary: summary,
                          busy: app.busy,
                          canDelete: summary.canDelete && identities.length > 1,
                          canDisable: summary.canDisable,
                          onTap: () => _activate(summary),
                          onToggle: () =>
                              _setEnabled(summary, !summary.enabled),
                          onClear: () => _clear(summary),
                          onDelete: () => _delete(summary),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _NewIdentityDialog extends StatefulWidget {
  const _NewIdentityDialog({required this.suggestion});

  final String suggestion;

  @override
  State<_NewIdentityDialog> createState() => _NewIdentityDialogState();
}

class _NewIdentityDialogState extends State<_NewIdentityDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.suggestion);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _name => _controller.text.trim().isEmpty
      ? widget.suggestion
      : _controller.text.trim();

  int get _byteLength => utf8.encode(_controller.text).length;

  void _submit() {
    final valid = validateAdvertName(_name);
    if (valid == null) {
      setState(() => _error = 'Enter a valid name');
      return;
    }
    Navigator.of(context).pop(valid);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New identity'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        inputFormatters: [
          _Utf8ByteLengthLimitingTextInputFormatter(maxAdvertNameBytes),
        ],
        decoration: InputDecoration(
          labelText: 'Name',
          helperText: 'Max $maxAdvertNameBytes bytes',
          counterText: '$_byteLength/$maxAdvertNameBytes bytes',
          errorText: _error,
          border: const OutlineInputBorder(),
        ),
        onChanged: (_) => setState(() => _error = null),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// Truncates edits at a UTF-8 byte limit rather than a character count.
class _Utf8ByteLengthLimitingTextInputFormatter extends TextInputFormatter {
  _Utf8ByteLengthLimitingTextInputFormatter(this.maxBytes);

  final int maxBytes;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (utf8.encode(newValue.text).length <= maxBytes) return newValue;
    final buffer = StringBuffer();
    var used = 0;
    for (final rune in newValue.text.runes) {
      final char = String.fromCharCode(rune);
      final size = utf8.encode(char).length;
      if (used + size > maxBytes) break;
      buffer.write(char);
      used += size;
    }
    final text = buffer.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({this.onCreate});

  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('No identities yet'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add),
            label: const Text('Create identity'),
          ),
        ],
      ),
    );
  }
}

class _AvatarWithRing extends StatelessWidget {
  const _AvatarWithRing({required this.name, required this.active});

  final String name;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatar = IdentityAvatar(name: name, size: 40);
    if (!active) return avatar;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: theme.colorScheme.primary, width: 2),
      ),
      child: avatar,
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.summary,
    required this.busy,
    required this.canDelete,
    required this.canDisable,
    required this.onTap,
    required this.onToggle,
    required this.onClear,
    required this.onDelete,
  });

  final IdentitySummary summary;
  final bool busy;
  final bool canDelete;
  final bool canDisable;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onClear;
  final VoidCallback onDelete;

  String get _toggleLabel =>
      summary.enabled ? 'Disable identity' : 'Enable identity';

  String get _status => identityAvailabilityLabel(summary);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        onTap: busy || !summary.keyAvailable || !summary.enabled ? null : onTap,
        leading: _AvatarWithRing(
          name: summary.name,
          active: summary.active,
        ),
        title: Row(
          children: [
            Flexible(
                child: Text(summary.name, overflow: TextOverflow.ellipsis)),
            if (summary.active) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Active',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              '#${summary.prefixHex} · $_status',
            ),
            Text(
              '${summary.channelCount} channels · '
              '${summary.contactCount} contacts',
            ),
            Tooltip(
              message:
                  'Waiting to sync; clears when the MeshCore app receives them.',
              child: Text(
                '${waitingToSyncLabel(summary.queuedDirect + summary.queuedChannel)} '
                '(${summary.queuedDirect} direct, '
                '${summary.queuedChannel} channel)',
              ),
            ),
            if (!summary.keyAvailable || summary.unavailableReason != null)
              Text(
                summary.unavailableReason ?? 'Key unavailable',
                style: TextStyle(color: theme.colorScheme.error),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              summary.active ? Icons.check_circle : Icons.chevron_right,
              color: summary.active ? theme.colorScheme.primary : null,
            ),
            PopupMenuButton<String>(
              enabled: !busy,
              onSelected: (value) {
                if (value == 'toggle') onToggle();
                if (value == 'clear') onClear();
                if (value == 'delete') onDelete();
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'toggle',
                  enabled: !summary.enabled || canDisable,
                  child: Text(_toggleLabel),
                ),
                const PopupMenuItem(
                  value: 'clear',
                  child: Text('Clear local data'),
                ),
                PopupMenuItem(
                  value: 'delete',
                  enabled: canDelete,
                  child: const Text('Delete identity'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
