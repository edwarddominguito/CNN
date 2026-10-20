import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../content/guide_topic.dart';
import '../content/rice_grades.dart';
import 'app_cards.dart';
import 'guide_quiz.dart';

/// Draws one block of a Guide page. GuideTopicScreen stacks these in order.
///
/// Everything is built from the shared cards in app_cards.dart and the theme's
/// text styles, so the Guide looks like the rest of the app.
class GuideBlockView extends StatelessWidget {
  final GuideBlock block;

  /// Opens another Guide page. Passed in so this file does not depend on the
  /// screen that uses it.
  final ValueChanged<GuideTopic> onOpenTopic;

  const GuideBlockView({super.key, required this.block, required this.onOpenTopic});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return switch (block) {
      GuideParagraph(:final text) => Text(text, style: textTheme.bodyMedium),
      GuideHeading(:final text) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(text, style: textTheme.titleMedium),
        ),
      GuideNote(:final text) => _NoteBox(text: text),
      GuideBullets(:final items) => _BulletCard(items: items),
      GuideSteps(:final steps) => _StepsCard(steps: steps),
      GuideCards(:final entries) => AppCardGrid(
          children: [for (final entry in entries) _EntryCard(entry: entry)],
        ),
      GuideList(:final entries) => _EntryListCard(entries: entries),
      GuideLinks(:final topics) => _Spaced(
          children: [
            for (final topic in topics)
              AppTile(
                icon: topic.icon,
                title: topic.title,
                subtitle: topic.summary,
                onTap: () => onOpenTopic(topic),
              ),
          ],
        ),
      GuideComparison(:final rows) => _Spaced(
          children: [for (final row in rows) _ComparisonCard(row: row)],
        ),
      GuideQuiz(:final questions) => GuideQuizView(questions: questions),
    };
  }
}

/// Children stacked with the gap the page itself uses between blocks.
class _Spaced extends StatelessWidget {
  final List<Widget> children;

  const _Spaced({required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          children[i],
        ],
      ],
    );
  }
}

/// The same amber note the prediction result uses, with an icon so the note
/// does not rely on colour alone.
class _NoteBox extends StatelessWidget {
  final String text;

  const _NoteBox({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kNoteSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: kAmber),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: kAmber),
            ),
          ),
        ],
      ),
    );
  }
}

class _BulletCard extends StatelessWidget {
  final List<String> items;

  const _BulletCard({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    final style = Theme.of(context).textTheme.bodyMedium;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // A text bullet scales and aligns with the line it starts.
                  Text('•', style: style),
                  const SizedBox(width: 10),
                  Expanded(child: Text(items[i], style: style)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StepsCard extends StatelessWidget {
  final List<String> steps;

  const _StepsCard({required this.steps});

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty) {
      return const SizedBox.shrink();
    }
    final textTheme = Theme.of(context).textTheme;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0)
              const Padding(
                // Centred under the 28-wide number above it.
                padding: EdgeInsets.only(left: 6, top: 4, bottom: 4),
                child: Icon(Icons.arrow_downward, size: 16, color: kMutedText),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: kSubtleSurface,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${i + 1}',
                    style: textTheme.bodySmall?.copyWith(
                      color: kHeadingText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(steps[i], style: textTheme.bodyMedium),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A titled card, laid out like AppTile but with readable body text instead of
/// a muted one-line subtitle.
class _EntryCard extends StatelessWidget {
  final GuideEntry entry;

  const _EntryCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final icon = entry.icon;

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 20, color: kPrimaryGreen),
            ),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.title, style: textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(entry.text, style: textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Entries inside one card, separated by hairlines, like the grade list on the
/// About screen.
class _EntryListCard extends StatelessWidget {
  final List<GuideEntry> entries;

  const _EntryListCard({required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }
    final textTheme = Theme.of(context).textTheme;

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entries[i].title, style: textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(entries[i].text, style: textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One aspect, then a labelled line for each grade, stacked so it fits any
/// phone width.
class _ComparisonCard extends StatelessWidget {
  final GradeComparisonRow row;

  const _ComparisonCard({required this.row});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(row.aspect, style: textTheme.titleMedium),
          for (final grade in riceGrades)
            if (row.values[grade] case final text?) ...[
              const SizedBox(height: 12),
              Text(
                grade.displayName,
                style: textTheme.bodySmall?.copyWith(
                  color: kHeadingText,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(text, style: textTheme.bodyMedium),
            ],
        ],
      ),
    );
  }
}
