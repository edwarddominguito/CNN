import 'package:flutter/widgets.dart';

import 'rice_grades.dart';

/// One page of the Guide: its title, the line shown in the Guide's list, and
/// the blocks GuideTopicScreen draws top to bottom.
///
/// A new page is a new [GuideTopic] in guide_content.dart. It needs no new
/// screen or widget.
class GuideTopic {
  final IconData icon;
  final String title;
  final String summary;
  final List<GuideBlock> blocks;

  const GuideTopic({
    required this.icon,
    required this.title,
    required this.summary,
    required this.blocks,
  });
}

/// A titled group of topics on the Guide screen.
class GuideSection {
  final String title;
  final List<GuideTopic> topics;

  const GuideSection({required this.title, required this.topics});
}

/// The kinds of content a Guide page can hold. Each has exactly one look,
/// drawn by GuideBlockView, so every page reads the same way.
sealed class GuideBlock {
  const GuideBlock();
}

/// A paragraph of body text.
class GuideParagraph extends GuideBlock {
  final String text;

  const GuideParagraph(this.text);
}

/// A small heading that starts a new part of the page.
class GuideHeading extends GuideBlock {
  final String text;

  const GuideHeading(this.text);
}

/// A highlighted remark, such as something the model does not do.
class GuideNote extends GuideBlock {
  final String text;

  const GuideNote(this.text);
}

/// A bulleted list inside one card.
class GuideBullets extends GuideBlock {
  final List<String> items;

  const GuideBullets(this.items);
}

/// Steps that happen in order, numbered from 1.
class GuideSteps extends GuideBlock {
  final List<String> steps;

  const GuideSteps(this.steps);
}

/// One titled item: a capture tip, a quality characteristic, a glossary term.
class GuideEntry {
  final String title;
  final String text;
  final IconData? icon;

  const GuideEntry({required this.title, required this.text, this.icon});
}

/// Entries drawn as separate cards.
class GuideCards extends GuideBlock {
  final List<GuideEntry> entries;

  const GuideCards(this.entries);
}

/// Entries listed inside one card, separated by lines. Suits long lists of
/// short items, such as the glossary.
class GuideList extends GuideBlock {
  final List<GuideEntry> entries;

  const GuideList(this.entries);
}

/// Links that open other Guide pages.
class GuideLinks extends GuideBlock {
  final List<GuideTopic> topics;

  const GuideLinks(this.topics);
}

/// The same aspects described for every rice grade, one card per aspect, so
/// the grades can be compared on a phone without a wide table.
class GuideComparison extends GuideBlock {
  final List<GradeComparisonRow> rows;

  const GuideComparison(this.rows);
}

/// One aspect of the comparison. A grade missing from [values] is skipped
/// rather than shown blank.
class GradeComparisonRow {
  final String aspect;
  final Map<RiceGrade, String> values;

  const GradeComparisonRow({required this.aspect, required this.values});
}

/// The multiple-choice quiz.
class GuideQuiz extends GuideBlock {
  final List<QuizQuestion> questions;

  const GuideQuiz(this.questions);
}

/// One quiz question with exactly one correct option.
class QuizQuestion {
  final String question;
  final List<String> options;

  /// Index into [options] of the correct answer.
  final int answerIndex;

  /// Shown after the user answers, whether they were right or not.
  final String explanation;

  const QuizQuestion({
    required this.question,
    required this.options,
    required this.answerIndex,
    required this.explanation,
  });

  /// Whether the quiz can show this question safely: some text, at least two
  /// options, and an answer that points at one of them.
  bool get isValid =>
      question.isNotEmpty &&
      options.length >= 2 &&
      answerIndex >= 0 &&
      answerIndex < options.length;
}
