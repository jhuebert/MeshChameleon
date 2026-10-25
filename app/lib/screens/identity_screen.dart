import 'package:flutter/material.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

class IdentityScreen extends StatefulWidget {
  const IdentityScreen({super.key});

  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  final _importController = TextEditingController();
  String? _exportHex;
  bool _resetting = false;

  @override
  void dispose() {
    _importController.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    final key = await context.read<AppState>().exportIdentity();
    setState(() => _exportHex = key == null ? null : bytesToHex(key));
  }

  Future<void> _import() async {
    final app = context.read<AppState>();
    try {
      final key = hexToBytes(_importController.text.trim());
      await app.importIdentity(key);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Identity imported')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    }
  }

  Future<bool> _confirmReset({required bool rotateIdentity}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        final title = rotateIdentity
            ? 'Reset virtual data and create a new identity?'
            : 'Reset virtual data?';
        final detail = rotateIdentity
            ? 'This permanently clears virtual preferences, contacts, '
                'channels, queued messages, advert paths, and custom settings, '
                'then creates a new virtual identity. The device connection and '
                'server port stay unchanged. If the new key cannot be saved, '
                'the data will remain reset with the old identity.'
            : 'This permanently clears virtual preferences, contacts, '
                'channels, queued messages, advert paths, and custom settings. '
                'Your identity, device connection, and server port stay '
                'unchanged. This cannot be undone.';
        return AlertDialog(
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
              child: const Text('Reset'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _reset({required bool rotateIdentity}) async {
    if (_resetting) return;
    if (!await _confirmReset(rotateIdentity: rotateIdentity)) return;
    if (!mounted) return;
    setState(() => _resetting = true);
    final app = context.read<AppState>();
    try {
      final result = await app.resetVirtualData(
        rotateIdentity: rotateIdentity,
      );
      if (!mounted) return;
      final message = result.partialKeyFailure
          ? 'Virtual data was reset, but the new identity could not be saved. '
              'The old identity remains active.'
          : result.identityRotated
              ? 'Virtual data reset; new identity active.'
              : 'Virtual data reset; identity kept.';
      if (result.identityRotated) _exportHex = null;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
            'Reset failed; previous virtual data was retained.',
          ),
        ));
      }
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final identity = context.watch<AppState>().identity;
    final pubkeyHex = identity == null ? null : bytesToHex(identity.publicKey);
    return Scaffold(
      appBar: AppBar(title: const Text('Identity')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Public key',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SelectableText(
            pubkeyHex ?? 'No identity. Generate or import one.',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Generate new identity'),
            onPressed: () => context.read<AppState>().generateIdentity(),
          ),
          const SizedBox(height: 24),
          const Text('Import', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _importController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '32-byte seed or 64-byte MeshCore key (hex)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.download),
            label: const Text('Import key'),
            onPressed: _import,
          ),
          const SizedBox(height: 24),
          const Text('Danger zone',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'Reset only virtual data. The device connection, physical radio '
            'settings, identity (unless selected), and server port are kept.',
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.delete_sweep),
            label: const Text('Reset virtual data'),
            onPressed: _resetting ? null : () => _reset(rotateIdentity: false),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.autorenew),
            label: const Text('Reset data and create new identity'),
            onPressed: _resetting ? null : () => _reset(rotateIdentity: true),
          ),
          const SizedBox(height: 24),
          const Text('Export', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.upload),
            label: const Text('Reveal 64-byte key'),
            onPressed: _export,
          ),
          if (_exportHex != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(
                _exportHex!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}
