import 'package:flutter/material.dart';

import 'guide_topic.dart';
import 'rice_grades.dart';

/// Everything the Guide says, in one place.
///
/// Rules this text follows, so later edits keep to them:
/// - The CNN is a classifier. It never detects, counts or measures defects, so
///   nothing here says it does.
/// - The three classes are this project's categories. The project cites no
///   official grading standard, so none is claimed.
/// - Confidence is the softmax probability of the predicted class. No accuracy
///   or "safe" threshold is given, because none has been validated.
/// - Facts about the model come from backend/docs/TRAINING_CODE_GUIDE.md,
///   backend/data/dataset/README.md and docs/DEVELOPMENT.md.

/// Repeated wherever the app might seem to judge characteristics one by one.
const _classifierReminder =
    'The class shown after a scan is chosen by the CNN from the whole photo. '
    'The app does not check these characteristics one by one.';

/// The Guide page for one rice grade, built from its data in rice_grades.dart.
GuideTopic gradeTopic(RiceGrade grade) {
  return GuideTopic(
    icon: Icons.grain,
    title: grade.displayName,
    summary: grade.summary,
    blocks: [
      GuideParagraph(grade.description),
      const GuideHeading('May be associated with'),
      GuideBullets(grade.characteristics),
      const GuideNote(_classifierReminder),
    ],
  );
}

final gradesTopic = GuideTopic(
  icon: Icons.grain,
  title: 'Rice Grades',
  summary: 'The three classes used by the system.',
  blocks: [
    const GuideParagraph(
      'The model sorts every rice photo into one of three classes. These are '
      'the categories this project was built around; the app does not claim '
      'that they follow an official grading standard.',
    ),
    GuideLinks([for (final grade in riceGrades) gradeTopic(grade)]),
    const GuideNote(
      'Regular-milled rice is not one of the classes. It was removed from the '
      "project's scope because enough independent samples could not be "
      'collected.',
    ),
  ],
);

const qualityTopic = GuideTopic(
  icon: Icons.search,
  title: 'Quality & Defects',
  summary: 'Common visual quality characteristics.',
  blocks: [
    GuideParagraph(
      'People examining rice often look at a few visible characteristics. '
      'Knowing them helps explain why rice samples can look different.',
    ),
    GuideNote(
      'The CNN does not detect, count, or measure any of these. It looks at '
      'the whole photo and chooses one of three classes.',
    ),
    GuideCards([
      GuideEntry(
        title: 'Broken grains',
        text: 'Pieces smaller than a whole grain. Broken grains are one visual '
            'characteristic that may be considered when examining rice quality.',
      ),
      GuideEntry(
        title: 'Discolored grains',
        text: 'Grains that look yellowish, brownish, or unevenly colored '
            'instead of white or translucent. Color is another characteristic '
            'that may be considered.',
      ),
      GuideEntry(
        title: 'Chalky grains',
        text: 'Grains, or parts of grains, that look opaque and chalk-white '
            'instead of translucent.',
      ),
      GuideEntry(
        title: 'Foreign material',
        text: 'Anything in the sample that is not rice, such as husk fragments '
            'or other small particles.',
      ),
    ]),
  ],
);

const comparisonTopic = GuideTopic(
  icon: Icons.compare_arrows,
  title: 'Grade Comparison',
  summary: 'Compare the three classes.',
  blocks: [
    GuideParagraph(
      'The same points, described for each class. These are general '
      'descriptions for learning, not rules the model follows.',
    ),
    GuideComparison([
      GradeComparisonRow(
        aspect: 'What it represents',
        values: {
          premiumGrade: 'The highest-quality samples in the project',
          wellMilledGrade: 'Milled rice samples, named after the milling process',
          poorQualityRiceMixGrade: 'Lower-quality or mixed rice samples',
        },
      ),
      GradeComparisonRow(
        aspect: 'Grains',
        values: {
          premiumGrade: 'Mostly whole, with few broken pieces',
          wellMilledGrade: 'Mostly white and milled; some broken pieces may be present',
          poorQualityRiceMixGrade: 'Broken pieces may be more common',
        },
      ),
      GradeComparisonRow(
        aspect: 'Appearance',
        values: {
          premiumGrade: 'Clean, with an even color',
          wellMilledGrade: 'Generally white from milling',
          poorQualityRiceMixGrade:
              'May include discolored or chalky grains, or foreign material',
        },
      ),
    ]),
    GuideNote(_classifierReminder),
  ],
);

const captureTopic = GuideTopic(
  icon: Icons.photo_camera_outlined,
  title: 'Capture Guide',
  summary: 'How to take a suitable rice photo.',
  blocks: [
    GuideParagraph(
      'A clear, consistent photo gives the model the best view of the grains.',
    ),
    GuideCards([
      GuideEntry(
        icon: Icons.wb_sunny_outlined,
        title: 'Even lighting',
        text: 'Use bright, even light. Avoid strong shadows and colored light.',
      ),
      GuideEntry(
        icon: Icons.center_focus_strong_outlined,
        title: 'Sharp focus',
        text: 'Hold the phone steady and make sure the grains are in focus. '
            'Blurry photos hide grain detail.',
      ),
      GuideEntry(
        icon: Icons.layers_clear_outlined,
        title: 'Plain, dark background',
        text: 'Use a plain, dark surface without patterns, like the background '
            "used for the project's training photos.",
      ),
      GuideEntry(
        icon: Icons.vertical_align_bottom,
        title: 'From above',
        text: 'Photograph mostly from directly above the grains.',
      ),
      GuideEntry(
        icon: Icons.crop_free,
        title: 'Rice in the center',
        text: 'Keep the grains in the middle of the frame. The model only looks '
            'at a square from the center of the photo.',
      ),
      GuideEntry(
        icon: Icons.grain,
        title: 'Spread the grains',
        text: 'Spread the grains so each one is visible, with little overlap.',
      ),
      GuideEntry(
        icon: Icons.zoom_in,
        title: 'No digital zoom',
        text: 'Avoid digital zoom. It lowers the detail in the photo.',
      ),
      GuideEntry(
        icon: Icons.inventory_2_outlined,
        title: 'One sample per photo',
        text: 'Photograph one rice sample at a time. Mixing samples in a single '
            'photo gives an unreliable result.',
      ),
    ]),
    GuideNote(
      'Image quality can affect classification results. Following these tips '
      'does not guarantee a correct result.',
    ),
  ],
);

const cnnTopic = GuideTopic(
  icon: Icons.account_tree_outlined,
  title: 'How the CNN Works',
  summary: 'How a photo becomes a result.',
  blocks: [
    GuideParagraph(
      'The app uses a convolutional neural network (CNN), a type of model '
      'designed for image classification. It was built with TensorFlow/Keras '
      "and trained on photos of this project's rice samples.",
    ),
    GuideHeading('From photo to result'),
    GuideSteps([
      'You capture or choose a rice photo.',
      'The app checks that the file is a readable image and sends it to the '
          'server.',
      'Image preparation: the server takes a square from the center of the '
          'photo and resizes it to the size the model expects.',
      'The CNN analyzes visual patterns in the image, such as edges, textures '
          'and shapes.',
      'The model gives a probability to each of the three classes.',
      'The class with the highest probability becomes the predicted class.',
      'The app shows the grade and its confidence.',
    ]),
    GuideHeading('MobileNetV2'),
    GuideParagraph(
      'The CNN is based on MobileNetV2, a compact network designed for mobile '
      'devices. MobileNetV2 was first trained on ImageNet, a large collection '
      'of general photos. This project added a few small layers on top and '
      'trained them on rice photos. Reusing a trained network this way is '
      'called transfer learning.',
    ),
    GuideHeading('What the model does not do'),
    GuideBullets([
      'It does not count grains or detect individual defects.',
      'It does not understand rice the way a person does. It matches patterns '
          'it learned from example photos.',
      'It always chooses one of its three classes, even for a photo that is '
          'not rice.',
    ]),
    GuideHeading('How it was tested'),
    GuideParagraph(
      'The model was evaluated with grouped 5-fold cross-validation. All photos '
      'of one rice sample stay together, so every test uses samples the model '
      'never saw during training.',
    ),
  ],
);

const confidenceTopic = GuideTopic(
  icon: Icons.percent,
  title: 'Confidence',
  summary: 'What the confidence value means.',
  blocks: [
    GuideParagraph(
      'Confidence indicates how strongly the model favored the selected class '
      'compared with its other available classes.',
    ),
    GuideParagraph(
      'For each photo, the model gives every class a probability, and the three '
      'probabilities add up to 100%. The highest one becomes the prediction, '
      'and that probability is shown as the confidence.',
    ),
    GuideNote('A higher confidence does not guarantee that the prediction is correct.'),
    GuideHeading('Reading the value'),
    GuideBullets([
      'With three classes, the confidence is always at least 33.3%.',
      'A value close to 33.3% means the model gave all three classes almost '
          'the same probability.',
      "Confidence describes one photo. It is not the model's overall accuracy.",
      'The model gives a confidence even for photos that are not rice.',
      'Lighting, focus and background can change the result and its confidence.',
    ]),
  ],
);

/// Every question is answered by something shown on another Guide page.
const quizQuestions = [
  QuizQuestion(
    question: 'What does the confidence value show?',
    options: [
      'How strongly the model favored the predicted class over the other classes',
      'The percentage of broken grains in the photo',
      'A guarantee that the prediction is correct',
    ],
    answerIndex: 0,
    explanation: 'Confidence is the probability the model gave its chosen class, '
        'compared with its other classes.',
  ),
  QuizQuestion(
    question: 'Does a high confidence guarantee a correct prediction?',
    options: [
      'Yes, a high value is always correct',
      'No, a high value can still be wrong',
    ],
    answerIndex: 1,
    explanation: 'A higher confidence does not guarantee that the prediction is '
        'correct.',
  ),
  QuizQuestion(
    question: 'Why should rice photos be sharp and evenly lit?',
    options: [
      'The server only accepts photos taken in daylight',
      'Image quality can affect the classification result',
      'It makes the upload faster',
    ],
    answerIndex: 1,
    explanation: 'Blur, poor lighting and strong shadows hide grain detail, and '
        'image quality can affect classification results.',
  ),
  QuizQuestion(
    question: 'Which of these is a recommended way to photograph rice?',
    options: [
      'Use digital zoom to get closer',
      'Place the grains on a patterned tablecloth',
      'Photograph from above with even lighting',
      'Pile the grains on top of each other',
    ],
    answerIndex: 2,
    explanation: 'The Capture Guide recommends even lighting, a plain dark '
        'background, photographing from above, and spreading the grains out.',
  ),
  QuizQuestion(
    question: 'What does the CNN do in this app?',
    options: [
      'Counts every broken grain in the photo',
      'Classifies the whole photo into one of three classes',
      'Reads the brand name on the rice package',
    ],
    answerIndex: 1,
    explanation: 'The CNN is an image classifier. It does not count grains or '
        'detect individual defects.',
  ),
  QuizQuestion(
    question: 'Which statement about broken grains is accurate?',
    options: [
      'They are one visual characteristic that may be considered when examining rice quality',
      'The app measures them and reports the count after every scan',
      'They only appear in photos that are out of focus',
    ],
    answerIndex: 0,
    explanation: 'Broken grains are general quality knowledge. The app does not '
        'detect or count them.',
  ),
  QuizQuestion(
    question: 'What happens if you photograph something that is not rice?',
    options: [
      'The app says the photo is not rice',
      'The model still chooses one of its three classes',
      'The model refuses to give an answer',
    ],
    answerIndex: 1,
    explanation: 'The model always chooses one of its classes, so it cannot tell '
        'you that a photo is not rice.',
  ),
];

const quizTopic = GuideTopic(
  icon: Icons.quiz_outlined,
  title: 'Mini Quiz',
  summary: 'Check what you have learned.',
  blocks: [
    GuideParagraph(
      'A few quick questions based on the Guide pages. Your answers are not '
      'saved anywhere.',
    ),
    GuideQuiz(quizQuestions),
  ],
);

/// Kept in alphabetical order; a test checks it.
const glossaryTopic = GuideTopic(
  icon: Icons.menu_book_outlined,
  title: 'Glossary',
  summary: 'Important terms in plain words.',
  blocks: [
    GuideList([
      GuideEntry(
        title: 'Batch',
        text: 'In this project, all the photos of one physical rice sample. '
            'Photos from the same batch are always kept together during '
            'training and testing.',
      ),
      GuideEntry(
        title: 'Classification',
        text: 'Sorting an input, such as a photo, into one of a fixed set of '
            'categories called classes.',
      ),
      GuideEntry(
        title: 'CNN',
        text: 'Convolutional neural network. A type of model designed for images '
            'that learns visual patterns, such as edges, textures and shapes, '
            'from example photos.',
      ),
      GuideEntry(
        title: 'Confidence',
        text: 'The probability the model gave its predicted class, shown as a '
            'percentage. A high confidence does not guarantee a correct '
            'prediction.',
      ),
      GuideEntry(
        title: 'Cross-validation',
        text: 'Testing a model by training and evaluating it several times, each '
            'time holding back a different part of the data. This project uses '
            'grouped 5-fold cross-validation.',
      ),
      GuideEntry(
        title: 'Image preprocessing',
        text: 'Preparing a photo before the model sees it. The server crops a '
            'square from the center of the photo and resizes it.',
      ),
      GuideEntry(
        title: 'MobileNetV2',
        text: 'A compact CNN designed for mobile devices. The model in this app '
            'is built on it.',
      ),
      GuideEntry(
        title: 'Poor-Quality Rice Mix',
        text: "The system's class for lower-quality or mixed rice. The model "
            'stores it as Poor-Quality-Rice-Mix.',
      ),
      GuideEntry(
        title: 'Prediction',
        text: 'The class the model chooses for a photo, shown with its confidence.',
      ),
      GuideEntry(
        title: 'Premium',
        text: 'The highest-quality class of the three used by the system.',
      ),
      GuideEntry(
        title: 'Transfer learning',
        text: 'Reusing a network already trained on a large, general task as the '
            'starting point for a new task.',
      ),
      GuideEntry(
        title: 'Well-Milled',
        text: "The system's class named after milling, the process that removes "
            'the husk and bran from rice.',
      ),
    ]),
  ],
);

/// Only sources that exist: the project's own documentation, and the published
/// paper and software behind the model it names.
const referencesTopic = GuideTopic(
  icon: Icons.library_books_outlined,
  title: 'References',
  summary: 'Sources for this Guide.',
  blocks: [
    GuideHeading('Project documentation'),
    GuideList([
      GuideEntry(
        title: 'Dataset documentation',
        text: 'The three rice classes, how samples were collected, and photo '
            'guidance.',
      ),
      GuideEntry(
        title: 'Training code guide',
        text: 'How the model is trained, tested with grouped 5-fold '
            'cross-validation, and served.',
      ),
      GuideEntry(
        title: 'Development notes',
        text: 'How the server turns the model output into a grade and '
            'confidence, and the known limitations.',
      ),
    ]),
    GuideHeading('Model and software'),
    GuideList([
      GuideEntry(
        title: 'MobileNetV2',
        text: 'Sandler, M., Howard, A., Zhu, M., Zhmoginov, A., & Chen, L.-C. '
            '(2018). MobileNetV2: Inverted residuals and linear bottlenecks. '
            'Proceedings of the IEEE Conference on Computer Vision and Pattern '
            'Recognition (CVPR).',
      ),
      GuideEntry(
        title: 'TensorFlow and Keras',
        text: 'The open-source machine learning libraries used to build, train '
            'and run the model (tensorflow.org, keras.io).',
      ),
    ]),
    GuideNote(
      'This Guide does not cite an official rice grading standard. Its '
      'descriptions of rice quality are general and for learning only.',
    ),
  ],
);

/// The Guide screen's list, in the order it is shown.
final guideSections = [
  GuideSection(
    title: 'Rice',
    topics: [gradesTopic, qualityTopic, comparisonTopic],
  ),
  const GuideSection(
    title: 'Scanning',
    topics: [captureTopic, cnnTopic, confidenceTopic],
  ),
  const GuideSection(
    title: 'Quiz & Reference',
    topics: [quizTopic, glossaryTopic, referencesTopic],
  ),
];
