import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../widgets/app_snack_bar.dart';

class LogScreen extends StatelessWidget {
  const LogScreen({super.key});

  Future<void> _copy(BuildContext context, List<String> logs) async {
    await Clipboard.setData(ClipboardData(text: logs.join('\n')));
    if (!context.mounted) return;
    showAppSnackBar(context, 'Log copied', replace: false);
  }

  @override
  Widget build(BuildContext context) {
    final logs = context.watch<AppState>().logs;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: 'Copy log',
            onPressed: logs.isEmpty ? null : () => _copy(context, logs),
          ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: logs.length,
        itemBuilder: (context, index) {
          final line = logs[logs.length - 1 - index];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(line,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          );
        },
      ),
    );
  }
}
