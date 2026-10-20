import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../content/guide_content.dart';
import '../content/rice_grades.dart';
import '../models/prediction_result.dart';
import '../screens/guide_topic_screen.dart';
import 'app_cards.dart';

/// What the CNN answered for this one image: the grade and the model's own
/// confidence. Failures are shown by the Scan screen instead, so this card is
/// only ever built for a real prediction.
class PredictionResultCard extends StatelessWidget {
  final PredictionResult result;

  const PredictionResultCard({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    // The backend sends confidence as 0-100 already (main.py /predict), so the
    // bar is the only place it gets divided.
    final confidence = result.confidence.clamp(0, 100).toDouble();

    // Null for a label the app does not know, which then gets no grade link.
    final grade = gradeForLabel(result.predictedGrade);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Classification Result', style: textTheme.bodySmall),
          const SizedBox(height: 6),
          // Display only: result.predictedGrade keeps the backend's exact value.
          Text(gradeDisplayName(result.predictedGrade), style: textTheme.headlineSmall),
          const SizedBox(height: 18),
          Text('Model Confidence', style: textTheme.bodySmall),
          const SizedBox(height: 6),
          Text(
            '${confidence.toStringAsFixed(1)}%',
            style: textTheme.titleMedium?.copyWith(color: kHeadingText),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: confidence / 100,
              minHeight: 6,
              backgroundColor: kSubtleSurface,
            ),
          ),
          if (result.note != null) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kNoteSurface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                result.note!,
                style: textTheme.bodySmall?.copyWith(color: kAmber),
              ),
            ),
          ],
          const SizedBox(height: 12),
          const Divider(),
          const SizedBox(height: 4),
          // Background reading in the Guide. Opening either page changes
          // nothing about this result.
          Wrap(
            spacing: 4,
            children: [
              if (grade != null)
                TextButton.icon(
                  onPressed: () => openGuideTopic(context, gradeTopic(grade)),
                  icon: const Icon(Icons.menu_book_outlined, size: 18),
                  label: const Text('About This Grade'),
                ),
              TextButton.icon(
                onPressed: () => openGuideTopic(context, confidenceTopic),
                icon: const Icon(Icons.help_outline, size: 18),
                label: const Text('Understanding Confidence'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
