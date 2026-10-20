import 'package:flutter/material.dart';

import '../content/guide_content.dart';
import '../widgets/app_cards.dart';
import '../widgets/app_scaffold.dart';
import 'guide_topic_screen.dart';

/// The Guide tab: a short list of learning topics. Each opens its own page, so
/// this screen stays a clean index rather than a wall of text.
///
/// The topics and their order come from guideSections in guide_content.dart.
class GuideScreen extends StatelessWidget {
  const GuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AppNavScaffold(
      currentIndex: 3,
      title: 'Guide',
      body: AppPage(
        children: [
          Text(
            'Learn about the rice classes, how to take a suitable photo, and how '
            'the model reaches its result.',
            style: textTheme.bodyMedium,
          ),
          for (final (index, section) in guideSections.indexed) ...[
            Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : 8),
              child: Text(section.title, style: textTheme.titleMedium),
            ),
            for (final topic in section.topics)
              AppTile(
                icon: topic.icon,
                title: topic.title,
                subtitle: topic.summary,
                onTap: () => openGuideTopic(context, topic),
              ),
          ],
        ],
      ),
    );
  }
}
