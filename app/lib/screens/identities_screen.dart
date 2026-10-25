import 'package:flutter/material.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/identity_runtime.dart';

class IdentitiesScreen extends StatefulWidget {
  const IdentitiesScreen({super.key});

  @override
  State<IdentitiesScreen> createState() => _IdentitiesScreenState();
}

class _IdentitiesScreenState extends State<IdentitiesScreen> {
  Future<void> _activate(IdentitySummary summary) async {
    final app = context.read<AppState>();
    if (app.busy || summary.active || !summary.keyAvailable) return;
    final ok = await app.activateIdentity(summary.id);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      _snack('Could not activate ${summary.name}');
    }
  }

  Future<void> _create() async {
    final app = context.read<AppState>();
    if (app.busy || app.identityDatabaseError != null) return;
    final suggestion = await app.suggestIdentityName();
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
    final app = context.read<AppState>();
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
    final app = context.read<AppState>();
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
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final error = app.identityDatabaseError;
    if (error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Identities')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.storage, size: 48),
                const SizedBox(height: 16),
                const Text('Identity database unavailable',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(error, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: app.busy ? null : app.loadIdentities,
                  child: const Text('Retry'),
                ),
              ],
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
          if (app.busy) const LinearProgressIndicator(),
          Expanded(
            child: identities.isEmpty
                ? _EmptyState(onCreate: app.busy ? null : _create)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                    itemCount: identities.length,
                    itemBuilder: (context, index) {
                      final summary = identities[index];
                      return _IdentityCard(
                        summary: summary,
                        busy: app.busy,
                        canDelete: !summary.active && identities.length > 1,
                        isLast: identities.length == 1,
                        onTap: () => _activate(summary),
                        onClear: () => _clear(summary),
                        onDelete: () => _delete(summary),
                      );
                    },
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

  void _submit() {
    final candidate = _controller.text.trim().isEmpty
        ? widget.suggestion
        : _controller.text.trim();
    final valid = validateAdvertName(candidate);
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
        decoration: InputDecoration(
          labelText: 'Name',
          helperText:
              'Up to 31 UTF-8 bytes. You can change it later in the MeshCore app.',
          errorText: _error,
          border: const OutlineInputBorder(),
        ),
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

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.summary,
    required this.busy,
    required this.canDelete,
    required this.isLast,
    required this.onTap,
    required this.onClear,
    required this.onDelete,
  });

  final IdentitySummary summary;
  final bool busy;
  final bool canDelete;
  final bool isLast;
  final VoidCallback onTap;
  final VoidCallback onClear;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        onTap: busy || !summary.keyAvailable ? null : onTap,
        leading: Icon(
          summary.active ? Icons.key : Icons.key_outlined,
          color: summary.active ? theme.colorScheme.primary : null,
        ),
        title: Row(
          children: [
            Flexible(child: Text(summary.name, overflow: TextOverflow.ellipsis)),
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
              '#${summary.prefixHex}'
              '${summary.live ? ' · Live' : ''}',
            ),
            Text(
              '${summary.channelCount} channels · '
              '${summary.contactCount} contacts',
            ),
            Tooltip(
              message:
                  'Waiting to sync; clears when the MeshCore app receives them.',
              child: Text(
                '${summary.queuedDirect} DMs queued · '
                '${summary.queuedChannel} channel messages queued',
              ),
            ),
            if (!summary.keyAvailable)
              Text(
                summary.unavailableReason ?? 'Key unavailable',
                style: TextStyle(color: theme.colorScheme.error),
              )
            else if (summary.unavailableReason != null)
              Text(
                summary.unavailableReason!,
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
                if (value == 'clear') onClear();
                if (value == 'delete') onDelete();
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'clear',
                  child: Text('Clear local data'),
                ),
                PopupMenuItem(
                  value: 'delete',
                  enabled: canDelete,
                  child: Text(
                    canDelete
                        ? 'Delete identity'
                        : summary.active
                            ? 'Activate another identity before deleting this one'
                            : isLast
                                ? 'At least one identity must remain'
                                : 'Delete identity',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
