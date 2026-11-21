import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_view_state.dart';
import '../services/identity_presentation.dart';
import '../widgets/identity_avatar.dart';

/// What the caller of [showSwitchIdentitySheet] should do when the sheet
/// closes.
enum SwitchIdentityOutcome {
  /// The user asked for the management screen; caller pushes it.
  manage,
}

/// Quick identity switcher.
///
/// Lists every identity with availability and queue status. Selection and
/// availability are separate: an enabled offline identity can be selected.
/// Activation reuses the same eligibility rules as the management screen and
/// only completes on success; failures keep the sheet open with feedback.
Future<SwitchIdentityOutcome?> showSwitchIdentitySheet(BuildContext context) =>
    showModalBottomSheet<SwitchIdentityOutcome>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _SwitchIdentitySheet(),
    );

class _SwitchIdentitySheet extends StatefulWidget {
  const _SwitchIdentitySheet();

  @override
  State<_SwitchIdentitySheet> createState() => _SwitchIdentitySheetState();
}

class _SwitchIdentitySheetState extends State<_SwitchIdentitySheet> {
  String? _activatingId;
  String? _failure;

  Future<void> _activate(IdentitySummary summary) async {
    final app = context.read<AppViewState>();
    if (app.busy || _activatingId != null) return;
    final current = app.identities.where((item) => item.id == summary.id);
    if (current.isEmpty || current.first.active || !current.first.canActivate) {
      return;
    }
    setState(() {
      _activatingId = summary.id;
      _failure = null;
    });
    final ok = await app.activateIdentity(summary.id);
    // The sheet may have been dismissed while activation was in flight;
    // never pop the underlying page or touch a disposed sheet.
    if (!mounted) return;
    if (ok && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
      return;
    }
    if (ok) return;
    setState(() {
      _activatingId = null;
      _failure = 'Could not activate ${summary.name}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppViewState>();
    final identities = app.identities;
    final liveCount = identities.where((item) => item.live).length;
    final enabledCount = identities.where((item) => item.enabled).length;
    final viewInsets = MediaQuery.viewInsetsOf(context);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.82,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 4),
                Text(
                  'Switch identity',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '${identities.length} '
                  '${identities.length == 1 ? 'identity' : 'identities'} · '
                  '$enabledCount enabled · $liveCount live. Switching disconnects the current '
                  'MeshCore app. Reconnect it if it does not reconnect '
                  'automatically.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                if (_failure != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _failure!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 8),
                for (final summary in identities)
                  _IdentityRow(
                    key: ValueKey(summary.id),
                    summary: summary,
                    activating: _activatingId == summary.id,
                    busy: app.busy || _activatingId != null,
                    onTap: () => _activate(summary),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () =>
                      Navigator.of(context).pop(SwitchIdentityOutcome.manage),
                  icon: const Icon(Icons.manage_accounts),
                  label: const Text('Manage identities'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IdentityRow extends StatelessWidget {
  const _IdentityRow({
    super.key,
    required this.summary,
    required this.activating,
    required this.busy,
    required this.onTap,
  });

  final IdentitySummary summary;
  final bool activating;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason = identityDisabledReason(summary);
    final eligible = reason == null;
    final waiting = summary.queuedDirect + summary.queuedChannel;
    final availability = identityAvailabilityLabel(summary);
    final semanticLabel = StringBuffer(summary.name)
      ..write(', #${summary.prefixHex}, $availability');
    if (summary.active) semanticLabel.write(', selected');
    if (waiting > 0) semanticLabel.write(', $waiting waiting to sync');
    if (reason != null) semanticLabel.write(', $reason');

    return Semantics(
      button: eligible && !summary.active,
      selected: summary.active,
      label: semanticLabel.toString(),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: eligible && !busy ? onTap : null,
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              children: [
                IdentityAvatar(name: summary.name, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        summary.name,
                        style: theme.textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '#${summary.prefixHex} · $availability',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (!eligible)
                        Text(
                          reason,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        )
                      else if (waiting > 0)
                        Text(
                          '$waiting waiting to sync',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (activating)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (summary.active)
                  Icon(Icons.check_circle, color: theme.colorScheme.primary)
                else
                  const SizedBox.shrink(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
