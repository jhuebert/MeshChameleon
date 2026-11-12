import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_view_state.dart';
import '../widgets/content_width.dart';
import '../widgets/info_row.dart';

/// Project information: what this app is, what build is installed, and the
/// legal terms. Works fully offline; no live polling.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buildInfo = context.watch<AppViewState>().buildInfo;

    return Scaffold(
      appBar: AppBar(title: const Text('About MeshChameleon')),
      body: SafeArea(
        child: ContentWidth(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: Column(
                  children: [
                    Image.asset(
                      'assets/branding/icon.png',
                      width: 80,
                      height: 80,
                      semanticLabel: 'MeshChameleon icon',
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'MeshChameleon',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'A MeshCore companion that lives on your phone.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Chip(
                      avatar: Icon(
                        Icons.tag,
                        size: 18,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                      label: Text('Version ${buildInfo.versionLabel}'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'This build',
                children: [
                  for (final entry in buildInfo.cardDetails)
                    InfoRow(
                      label: entry.key,
                      value: entry.value,
                      labelWidth: 88,
                      stackBelow: 260,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'Licenses',
                children: [
                  Text(
                    'MeshChameleon is MIT licensed (Copyright (c) 2026 Jason '
                    'Huebert). Parts of the protocol implementation are '
                    'adapted from MIT-licensed projects; see the bundled '
                    'attribution notice.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.gavel_outlined),
                    title: const Text('Open-source licenses'),
                    subtitle: const Text(
                      'Flutter, plugins, MeshChameleon, and adapted sources',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showLicensePage(
                      context: context,
                      applicationName: 'MeshChameleon',
                      applicationVersion: buildInfo.versionLabel,
                      applicationIcon: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Image.asset(
                          'assets/branding/icon.png',
                          width: 96,
                          semanticLabel: 'MeshChameleon icon',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
      ],
    );
  }
}
