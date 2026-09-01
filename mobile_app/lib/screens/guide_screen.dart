import 'package:flutter/material.dart';

import '../widgets/app_cards.dart';
import '../widgets/app_scaffold.dart';

/// Advice on how to photograph a rice sample.
class GuideScreen extends StatelessWidget {
  const GuideScreen({super.key});

  // Add a row here and the grid picks it up. Nothing else needs editing.
  static const _tips = [
    (
      Icons.wb_sunny_outlined,
      'Lighting',
      'Use bright, even light. Avoid hard shadows and coloured lighting.',
    ),
    (
      Icons.center_focus_strong_outlined,
      'Framing',
      'Fill the frame with grains. The model only sees a square crop from the middle of the photo.',
    ),
    (
      Icons.layers_clear_outlined,
      'Background',
      'Use a plain surface so the model learns rice quality, not table texture.',
    ),
    (
      Icons.inventory_2_outlined,
      'One sample',
      'Photograph one rice sample at a time. Mixing samples in a single photo gives an unreliable grade.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return AppNavScaffold(
      currentIndex: 3,
      title: 'Guide',
      body: AppPage(
        children: [
          Text(
            'Four things that decide whether a prediction is worth trusting.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          AppCardGrid(
            children: [
              for (final (icon, title, text) in _tips)
                AppInfoCard(icon: icon, title: title, text: text),
            ],
          ),
        ],
      ),
    );
  }
}
