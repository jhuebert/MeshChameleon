import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/backup_codec.dart';
import '../services/backup_service.dart';

/// User-facing backup and restore, reachable from the Home screen.
///
/// The flow is deliberately short: pick a passphrase, pick a file; or pick a
/// file, enter the passphrase, confirm a plain summary. No external tooling or
/// documentation is needed.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  bool _working = false;

  String _dateStamp() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '${now.year}-$month-$day';
  }

  Future<void> _backUp() async {
    final passphrase = await showDialog<String>(
      context: context,
      builder: (_) => const _PassphraseDialog(create: true),
    );
    if (passphrase == null || !mounted) return;

    setState(() => _working = true);
    try {
      final bytes = await context.read<AppState>().createBackup(passphrase);
      final name = 'meshchameleon-${_dateStamp()}.mcbackup';
      final path = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(data: bytes, fileName: name),
      );
      if (!mounted) return;
      if (path != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backup saved')),
        );
      }
    } on BackupException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError('Could not create the backup.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _restore() async {
    String? path;
    try {
      path = await FlutterFileDialog.pickFile(
        params: const OpenFileDialogParams(copyFileToCacheDir: true),
      );
    } catch (_) {
      _showError('Could not open the file picker.');
      return;
    }
    if (path == null || !mounted) return;

    Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (_) {
      _showError('Could not read that file.');
      return;
    }
    if (bytes.length > maxBackupBytes) {
      _showError('That backup file is too large.');
      return;
    }
    if (!mounted) return;

    final passphrase = await showDialog<String>(
      context: context,
      builder: (_) => const _PassphraseDialog(create: false),
    );
    if (passphrase == null || !mounted) return;

    setState(() => _working = true);
    try {
      final preview = await context.read<AppState>().inspectBackup(
            bytes,
            passphrase,
          );
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => _RestoreSummaryDialog(preview: preview),
      );
      if (confirmed != true || !mounted) return;

      final restored = await context.read<AppState>().restoreBackup(preview);
      if (!mounted) return;
      if (restored) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backup restored')),
        );
      } else {
        _showError(
            'Could not restore the backup. Your previous data was kept.');
      }
    } on BackupException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError('Could not restore the backup.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Backup & restore'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & restore')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 32,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'One encrypted file',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Save your identities, contacts, channels, messages, and '
                    'settings in one file. You choose the passphrase; without '
                    'it the file cannot be opened.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _working ? null : _backUp,
            icon: const Icon(Icons.save_alt),
            label: const Text('Back up now'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _working ? null : _restore,
            icon: const Icon(Icons.restore),
            label: const Text('Restore from backup'),
          ),
          if (_working) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 24),
          Text(
            'Keep the file and passphrase safe',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          const Text(
            'The backup contains your private identity keys. Anyone with the '
            'file and passphrase can use your identities. MeshChameleon cannot '
            'recover a lost passphrase.',
          ),
        ],
      ),
    );
  }
}

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({required this.create});

  final bool create;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  bool _hide = true;
  String? _error;

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _passphrase.text;
    if (value.isEmpty) {
      setState(() => _error = 'Enter the passphrase');
      return;
    }
    if (widget.create) {
      if (value.length < minBackupPassphraseLength) {
        setState(() =>
            _error = 'Use at least $minBackupPassphraseLength characters');
        return;
      }
      if (value != _confirm.text) {
        setState(() => _error = 'The passphrases do not match');
        return;
      }
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(
        widget.create
            ? 'Choose a backup passphrase'
            : 'Enter backup passphrase',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.create) ...[
              Text(
                'Use at least $minBackupPassphraseLength characters. You will '
                'need it to restore this backup.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _passphrase,
              obscureText: _hide,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Passphrase',
                suffixIcon: IconButton(
                  tooltip: _hide ? 'Show passphrase' : 'Hide passphrase',
                  icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _hide = !_hide),
                ),
              ),
              onSubmitted: (_) {
                if (!widget.create) _submit();
              },
            ),
            if (widget.create) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _confirm,
                obscureText: _hide,
                decoration: const InputDecoration(
                  labelText: 'Confirm passphrase',
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              Text(
                'Anyone with the file and passphrase can use your identities.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.create ? 'Continue' : 'Open backup'),
        ),
      ],
    );
  }
}

class _RestoreSummaryDialog extends StatelessWidget {
  const _RestoreSummaryDialog({required this.preview});

  final BackupPreview preview;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Restore this backup?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SummaryRow(
              icon: Icons.key_outlined,
              value: '${preview.identityCount} '
                  '${preview.identityCount == 1 ? 'identity' : 'identities'}',
            ),
            _SummaryRow(
              icon: Icons.people_outline,
              value: '${preview.contactCount} contacts',
            ),
            _SummaryRow(
              icon: Icons.tag,
              value: '${preview.channelCount} channels',
            ),
            _SummaryRow(
              icon: Icons.forum_outlined,
              value: '${preview.messageCount} messages',
            ),
            const SizedBox(height: 12),
            const Text(
              'This replaces all local identities, contacts, channels, '
              'messages, and settings on this phone. The device link and proxy '
              'will stop. A recovery copy of the current identity files stays '
              'on this phone.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Replace local data'),
        ),
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.icon, required this.value});

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(value),
        ],
      ),
    );
  }
}
