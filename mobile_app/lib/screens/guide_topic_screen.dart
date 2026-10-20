import 'package:flutter/material.dart';

import '../content/guide_topic.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/guide_blocks.dart';

/// One Guide page. It draws whatever blocks its topic holds, so every topic,
/// from Rice Grades to the quiz, uses this same screen.
class GuideTopicScreen extends StatelessWidget {
  final GuideTopic topic;

  const GuideTopicScreen({super.key, required this.topic});

  @override
  Widget build(BuildContext context) {
    return AppNavScaffold(
      currentIndex: 3,
      title: topic.title,
      isSubPage: true,
      body: AppPage(
        children: [
          for (final block in topic.blocks)
            GuideBlockView(
              block: block,
              onOpenTopic: (next) => openGuideTopic(context, next),
            ),
        ],
      ),
    );
  }
}

/// Opens [topic] on top of the current screen.
///
/// A second tap that lands while the first page is still opening is ignored,
/// so a quick double tap never opens the same page twice.
void openGuideTopic(BuildContext context, GuideTopic topic) {
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) {
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (context) => GuideTopicScreen(topic: topic)),
  );
}
