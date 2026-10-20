import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../content/guide_topic.dart';
import 'app_cards.dart';

/// The Guide's multiple-choice quiz.
///
/// All of its state lives here and is forgotten when the page closes. Nothing
/// is saved, sent to the backend, or shared.
class GuideQuizView extends StatefulWidget {
  final List<QuizQuestion> questions;

  const GuideQuizView({super.key, required this.questions});

  @override
  State<GuideQuizView> createState() => _GuideQuizViewState();
}

class _GuideQuizViewState extends State<GuideQuizView>
    with AutomaticKeepAliveClientMixin {
  /// Only questions that can be answered. A malformed one is left out rather
  /// than allowed to break the quiz.
  late List<QuizQuestion> _questions;

  int _current = 0; // index of the question on screen
  int? _chosen; // the option picked for it; null until answered
  int _score = 0; // questions answered correctly so far

  @override
  void initState() {
    super.initState();
    _questions = _usable(widget.questions);
  }

  @override
  void didUpdateWidget(GuideQuizView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Different questions start a new quiz, instead of carrying over answers
    // and a position that belong to the old ones.
    if (!listEquals(oldWidget.questions, widget.questions)) {
      _questions = _usable(widget.questions);
      _current = 0;
      _chosen = null;
      _score = 0;
    }
  }

  static List<QuizQuestion> _usable(List<QuizQuestion> questions) =>
      questions.where((question) => question.isValid).toList();

  // The page is a scrolling list; keeping this alive means scrolling can
  // never reset a quiz in progress.
  @override
  bool get wantKeepAlive => true;

  bool get _finished => _current >= _questions.length;

  void _choose(int option) {
    if (_finished || _chosen != null) {
      return; // One answer per question.
    }
    setState(() {
      _chosen = option;
      if (option == _questions[_current].answerIndex) {
        _score++;
      }
    });
  }

  void _next() {
    if (_chosen == null) {
      return;
    }
    setState(() {
      _current++;
      _chosen = null;
    });
    _showFromTop();
  }

  void _restart() {
    setState(() {
      _current = 0;
      _chosen = null;
      _score = 0;
    });
    _showFromTop();
  }

  /// After the content changes, scroll so it starts at the top of the screen
  /// instead of wherever the previous question ended.
  void _showFromTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Scrollable.ensureVisible(context, duration: const Duration(milliseconds: 200));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_questions.isEmpty) {
      return const AppEmptyState(
        icon: Icons.quiz_outlined,
        title: 'No questions available',
        message: 'The quiz has no questions to show right now.',
      );
    }
    if (_finished) {
      return _QuizScore(score: _score, total: _questions.length, onRestart: _restart);
    }

    final textTheme = Theme.of(context).textTheme;
    final question = _questions[_current];
    final chosen = _chosen;
    final isLast = _current == _questions.length - 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Question ${_current + 1} of ${_questions.length}',
                style: textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              Text(question.question, style: textTheme.titleMedium),
            ],
          ),
        ),
        for (var i = 0; i < question.options.length; i++) ...[
          const SizedBox(height: 10),
          _OptionCard(
            text: question.options[i],
            state: _optionState(i, question, chosen),
            onTap: chosen == null ? () => _choose(i) : null,
          ),
        ],
        if (chosen != null) ...[
          const SizedBox(height: 12),
          _Feedback(
            correct: chosen == question.answerIndex,
            explanation: question.explanation,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _next,
            child: Text(isLast ? 'See Score' : 'Next Question'),
          ),
        ],
      ],
    );
  }

  _OptionState _optionState(int option, QuizQuestion question, int? chosen) {
    if (chosen == null) {
      return _OptionState.open;
    }
    if (option == question.answerIndex) {
      return _OptionState.correct;
    }
    return option == chosen ? _OptionState.wrong : _OptionState.closed;
  }
}

enum _OptionState { open, correct, wrong, closed }

/// One answer. After answering, the right option and a wrong pick are each
/// marked with an icon and a word as well as a colour.
class _OptionCard extends StatelessWidget {
  final String text;
  final _OptionState state;
  final VoidCallback? onTap;

  const _OptionCard({required this.text, required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final (icon, color, label) = switch (state) {
      _OptionState.open => (Icons.radio_button_unchecked, kMutedText, null),
      _OptionState.correct => (Icons.check_circle, kPrimaryGreen, 'Correct answer'),
      _OptionState.wrong => (Icons.cancel, kErrorText, 'Your answer'),
      _OptionState.closed => (Icons.radio_button_unchecked, kBorderColor, null),
    };

    return Semantics(
      button: true,
      enabled: onTap != null,
      child: AppCard(
        onTap: onTap,
        color: state == _OptionState.wrong ? kErrorSurface : kSurface,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text, style: textTheme.bodyMedium?.copyWith(color: kHeadingText)),
                  if (label != null) ...[
                    const SizedBox(height: 2),
                    Text(label, style: textTheme.bodySmall?.copyWith(color: color)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Feedback extends StatelessWidget {
  final bool correct;
  final String explanation;

  const _Feedback({required this.correct, required this.explanation});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    // Announced by screen readers as soon as it appears.
    return Semantics(
      liveRegion: true,
      child: AppCard(
        color: correct ? kSubtleSurface : kErrorSurface,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              correct ? Icons.check_circle_outline : Icons.highlight_off,
              size: 20,
              color: correct ? kPrimaryGreen : kErrorText,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(correct ? 'Correct' : 'Not quite', style: textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(explanation, style: textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuizScore extends StatelessWidget {
  final int score;
  final int total;
  final VoidCallback onRestart;

  const _QuizScore({required this.score, required this.total, required this.onRestart});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      liveRegion: true,
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.task_alt, size: 28, color: kPrimaryGreen),
            const SizedBox(height: 14),
            Text('Quiz complete', style: textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '$score of $total correct',
              textAlign: TextAlign.center,
              style: textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Review any Guide page and try again whenever you like.',
              textAlign: TextAlign.center,
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRestart,
              icon: const Icon(Icons.refresh, size: 20),
              label: const Text('Restart Quiz'),
            ),
          ],
        ),
      ),
    );
  }
}
