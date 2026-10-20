import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_app/content/guide_content.dart';
import 'package:mobile_app/content/guide_topic.dart';
import 'package:mobile_app/content/rice_grades.dart';
import 'package:mobile_app/main.dart';
import 'package:mobile_app/models/prediction_history_entry.dart';
import 'package:mobile_app/models/prediction_result.dart';
import 'package:mobile_app/screens/guide_topic_screen.dart';
import 'package:mobile_app/screens/history_screen.dart';
import 'package:mobile_app/services/rice_api_service.dart';
import 'package:mobile_app/widgets/guide_quiz.dart';
import 'package:mobile_app/widgets/prediction_result_card.dart';

/// Sets the test window. A tall window lays out every item of a scrolling page
/// at once, so an overflow anywhere on it is reported, not just on screen.
void useWindow(WidgetTester tester, Size size, {double textScale = 1}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Widget inList(Widget child) => MaterialApp(home: Scaffold(body: ListView(children: [child])));

void main() {
  // Every Guide page, including the three grade pages.
  final topics = [
    for (final section in guideSections) ...section.topics,
    for (final grade in riceGrades) gradeTopic(grade),
  ];

  group('Guide content', () {
    test('every topic has a title, a summary and content', () {
      for (final topic in topics) {
        expect(topic.title, isNotEmpty);
        expect(topic.summary, isNotEmpty);
        expect(topic.blocks, isNotEmpty, reason: topic.title);
      }
    });

    test('topic titles are unique', () {
      final titles = topics.map((topic) => topic.title).toList();
      expect(titles.toSet().length, titles.length);
    });

    test('the glossary is alphabetical', () {
      final terms = glossaryTopic.blocks
          .whereType<GuideList>()
          .single
          .entries
          .map((entry) => entry.title.toLowerCase())
          .toList();
      expect(terms, [...terms]..sort());
    });

    test('the comparison describes every grade in every row', () {
      final rows = comparisonTopic.blocks.whereType<GuideComparison>().single.rows;
      for (final row in rows) {
        expect(row.values.keys.toSet(), riceGrades.toSet(), reason: row.aspect);
      }
    });

    test('the quiz has 5 to 8 valid questions with distinct options', () {
      expect(quizQuestions.length, inInclusiveRange(5, 8));
      for (final question in quizQuestions) {
        expect(question.isValid, isTrue, reason: question.question);
        expect(question.options.toSet().length, question.options.length);
      }
    });
  });

  group('Guide pages lay out without overflow', () {
    for (final width in [320.0, 360.0, 412.0, 1400.0]) {
      testWidgets('all pages at ${width.toInt()}px', (tester) async {
        useWindow(tester, Size(width, 6000));
        for (final topic in topics) {
          await tester.pumpWidget(MaterialApp(home: GuideTopicScreen(topic: topic)));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: topic.title);
        }
      });
    }

    testWidgets('all pages with large text on a small phone', (tester) async {
      useWindow(tester, const Size(320, 6000), textScale: 1.3);
      for (final topic in topics) {
        await tester.pumpWidget(MaterialApp(home: GuideTopicScreen(topic: topic)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: topic.title);
      }
    });
  });

  group('Guide navigation', () {
    Finder navTab(String label) =>
        find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

    // Each test uses a window tall enough to show the whole Guide list, so
    // every row is on screen and tappable.
    testWidgets('the Guide tab opens topics, and back returns step by step',
        (tester) async {
      useWindow(tester, const Size(412, 1600));
      await tester.pumpWidget(const RiceGraderApp());
      await tester.pumpAndSettle();

      await tester.tap(navTab('Guide'));
      await tester.pumpAndSettle();
      expect(find.text('Quiz & Reference'), findsOneWidget);

      await tester.tap(find.text('Rice Grades'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Poor-Quality Rice Mix'));
      await tester.pumpAndSettle();
      expect(find.text(poorQualityRiceMixGrade.description), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text(poorQualityRiceMixGrade.description), findsNothing);
      expect(find.text('Poor-Quality Rice Mix'), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Quiz & Reference'), findsOneWidget);
    });

    testWidgets('the Guide tab on a topic page returns to the Guide list',
        (tester) async {
      useWindow(tester, const Size(412, 1600));
      await tester.pumpWidget(const RiceGraderApp());
      await tester.pumpAndSettle();
      await tester.tap(navTab('Guide'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Capture Guide'));
      await tester.pumpAndSettle();
      expect(find.text('Quiz & Reference'), findsNothing);

      await tester.tap(navTab('Guide'));
      await tester.pumpAndSettle();
      expect(find.text('Quiz & Reference'), findsOneWidget);
    });

    testWidgets('a double tap opens a topic only once', (tester) async {
      useWindow(tester, const Size(412, 1600));
      await tester.pumpWidget(const RiceGraderApp());
      await tester.pumpAndSettle();
      await tester.tap(navTab('Guide'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Glossary'));
      // Lands while the first page is opening, so it is expected to be ignored.
      await tester.tap(find.text('Glossary'), warnIfMissed: false);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Quiz & Reference'), findsOneWidget);
    });
  });

  group('Mini quiz', () {
    const twoQuestions = [
      QuizQuestion(question: 'First?', options: ['A', 'B'], answerIndex: 0, explanation: 'E1'),
      QuizQuestion(question: 'Second?', options: ['C', 'D'], answerIndex: 1, explanation: 'E2'),
    ];

    testWidgets('scores answers, then restarts from a clean slate', (tester) async {
      useWindow(tester, const Size(320, 1200));
      await tester.pumpWidget(inList(const GuideQuizView(questions: twoQuestions)));
      expect(find.text('Question 1 of 2'), findsOneWidget);

      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      expect(find.text('Correct'), findsOneWidget);
      expect(find.text('E1'), findsOneWidget);

      await tester.tap(find.text('Next Question'));
      await tester.pumpAndSettle();
      expect(find.text('Question 2 of 2'), findsOneWidget);

      await tester.tap(find.text('C'));
      await tester.pumpAndSettle();
      expect(find.text('Not quite'), findsOneWidget);
      expect(find.text('Your answer'), findsOneWidget);
      expect(find.text('Correct answer'), findsOneWidget);

      await tester.tap(find.text('See Score'));
      await tester.pumpAndSettle();
      expect(find.text('1 of 2 correct'), findsOneWidget);

      await tester.tap(find.text('Restart Quiz'));
      await tester.pumpAndSettle();
      expect(find.text('Question 1 of 2'), findsOneWidget);

      for (final answer in ['A', 'D']) {
        await tester.tap(find.text(answer));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
      }
      expect(find.text('2 of 2 correct'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('only the first answer to a question counts', (tester) async {
      await tester.pumpWidget(inList(const GuideQuizView(questions: [
        QuizQuestion(question: 'Only?', options: ['Right', 'Wrong'], answerIndex: 0, explanation: 'E'),
      ])));

      await tester.tap(find.text('Wrong'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Right'));
      await tester.pumpAndSettle();
      expect(find.text('Not quite'), findsOneWidget);

      await tester.tap(find.text('See Score'));
      await tester.pumpAndSettle();
      expect(find.text('0 of 1 correct'), findsOneWidget);
    });

    testWidgets('skips malformed questions and survives having none', (tester) async {
      await tester.pumpWidget(inList(const GuideQuizView(questions: [
        QuizQuestion(question: 'Good?', options: ['Yes', 'No'], answerIndex: 0, explanation: 'E'),
        QuizQuestion(question: 'One option?', options: ['Only'], answerIndex: 0, explanation: 'E'),
        QuizQuestion(question: 'Bad answer?', options: ['X', 'Y'], answerIndex: 5, explanation: 'E'),
      ])));
      expect(find.text('Question 1 of 1'), findsOneWidget);

      await tester.pumpWidget(inList(const GuideQuizView(questions: [])));
      expect(find.text('No questions available'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Grade display names never change backend values', () {
    test('Poor-Quality-Rice-Mix is only reformatted for display', () {
      expect(riceGrades.map((grade) => grade.label),
          ['Premium', 'Well-Milled', 'Poor-Quality-Rice-Mix']);
      expect(gradeDisplayName('Poor-Quality-Rice-Mix'), 'Poor-Quality Rice Mix');
      expect(gradeDisplayName('Premium'), 'Premium');
      expect(gradeDisplayName('Prediction Failed'), 'Prediction Failed');

      final result = PredictionResult.fromJson({
        'predicted_grade': 'Poor-Quality-Rice-Mix',
        'confidence': '81.25',
      });
      expect(result.predictedGrade, 'Poor-Quality-Rice-Mix');
      expect(result.confidence, 81.25);

      final entry = PredictionHistoryEntry(
        predictedGrade: result.predictedGrade,
        confidence: result.confidence,
        createdAt: DateTime(2026),
      );
      expect(entry.toJson()['predictedGrade'], 'Poor-Quality-Rice-Mix');
    });

    testWidgets('the result card shows the display name and links to the Guide',
        (tester) async {
      useWindow(tester, const Size(320, 900));
      await tester.pumpWidget(inList(const PredictionResultCard(
        result: PredictionResult(predictedGrade: 'Poor-Quality-Rice-Mix', confidence: 72.44),
      )));
      expect(find.text('Poor-Quality Rice Mix'), findsOneWidget);
      expect(find.text('72.4%'), findsOneWidget);

      await tester.tap(find.text('About This Grade'));
      await tester.pumpAndSettle();
      expect(find.text(poorQualityRiceMixGrade.description), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('72.4%'), findsOneWidget);

      await tester.tap(find.text('Understanding Confidence'));
      await tester.pumpAndSettle();
      expect(
        find.text('A higher confidence does not guarantee that the prediction is correct.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a label the app does not know gets no grade link', (tester) async {
      await tester.pumpWidget(inList(const PredictionResultCard(
        result: PredictionResult(predictedGrade: 'Unknown', confidence: 50),
      )));
      expect(find.text('Unknown'), findsOneWidget);
      expect(find.text('About This Grade'), findsNothing);
      expect(find.text('Understanding Confidence'), findsOneWidget);
    });

    const storedRow = '{"predictedGrade":"Poor-Quality-Rice-Mix","confidence":64.2,'
        '"createdAt":"2026-01-03T03:04:05.000"}';

    testWidgets('history shows the display name', (tester) async {
      SharedPreferences.setMockInitialValues({'prediction_history': [storedRow]});
      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Poor-Quality Rice Mix'), findsOneWidget);
      expect(find.text('64.20% confidence'), findsOneWidget);
    });

    test('history keeps the stored backend label', () async {
      SharedPreferences.setMockInitialValues({'prediction_history': [storedRow]});
      final entries = await RiceApiService().getHistory();
      expect(entries.single.predictedGrade, 'Poor-Quality-Rice-Mix');
    });
  });
}
