import 'package:flutter/material.dart';

import '../widgets/app_cards.dart';
import '../widgets/app_scaffold.dart';

/// The first screen: one line of context, then the way in to everything else.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  // Add a row here and a new shortcut appears. Nothing else to edit.
  static const _shortcuts = [
    (
      Icons.camera_alt_outlined,
      'Scan Rice',
      'Capture or upload a sample and predict its grade.',
      '/scan',
    ),
    (
      Icons.history_outlined,
      'History',
      'Review recent predictions.',
      '/history',
    ),
    (
      Icons.help_outline,
      'Guide',
      'Rice grades, photo tips, and how the model works.',
      '/guide',
    ),
    (
      Icons.info_outline,
      'About',
      'What this app does and the grades it supports.',
      '/about',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return AppNavScaffold(
      currentIndex: 0,
      title: 'Rice Classifier',
      body: AppPage(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'CNN rice quality classification. Scan a sample to get a grade '
              'and a confidence score.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pushNamed(context, '/scan'),
            icon: const Icon(Icons.camera_alt_outlined, size: 20),
            label: const Text('Start Scan'),
          ),
          for (final (icon, title, subtitle, route) in _shortcuts)
            AppTile(
              icon: icon,
              title: title,
              subtitle: subtitle,
              onTap: () => Navigator.pushNamed(context, route),
            ),
        ],
      ),
    );
  }
}
