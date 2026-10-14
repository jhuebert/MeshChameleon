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

  @override
  Widget build(BuildContext context) {
    final identity = context.watch<AppState>().identity;
    final pubkeyHex =
        identity == null ? null : bytesToHex(identity.publicKey);
    return Scaffold(
      appBar: AppBar(title: const Text('Identity')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Public key', style: TextStyle(fontWeight: FontWeight.bold)),
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
