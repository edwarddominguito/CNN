import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../content/rice_grades.dart';
import '../widgets/app_cards.dart';
import '../widgets/app_scaffold.dart';

/// What the app is and which grades it can predict. Nothing here changes at
/// runtime, so the screen holds no state.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AppNavScaffold(
      currentIndex: 4,
      title: 'About',
      body: AppPage(
        children: [
          Text('Rice Classifier', style: textTheme.titleLarge),
          Text(
            'A mobile application for identifying the grade of rice grains from '
            'a photo. Take or choose a photo on the Scan screen to classify a '
            'sample.',
            style: textTheme.bodyMedium,
          ),
          Text('Supported Grades', style: textTheme.titleMedium),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                // The same display names the rest of the app uses.
                for (var i = 0; i < riceGrades.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _GradeRow(grade: riceGrades[i].displayName),
                ],
              ],
            ),
          ),
          Text('Version 1.0', style: textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// One grade inside the card, laid out like the icon-and-title rows the rest
/// of the app uses.
class _GradeRow extends StatelessWidget {
  final String grade;

  const _GradeRow({required this.grade});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          const Icon(Icons.grain, size: 20, color: kPrimaryGreen),
          const SizedBox(width: 14),
          // Expanded so a long grade wraps instead of overflowing the row.
          Expanded(
            child: Text(grade, style: Theme.of(context).textTheme.titleMedium),
          ),
        ],
      ),
    );
  }
}
