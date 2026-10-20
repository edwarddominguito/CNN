/// The rice classes the CNN can return, and how the app writes them on screen.
///
/// [RiceGrade.label] is the exact value the backend sends as `predicted_grade`
/// and stores in history. The app never changes it. [RiceGrade.displayName] is
/// only for drawing text.
///
/// The descriptions are general and kept deliberately careful: the project does
/// not cite an official grading standard, so nothing here claims to be one.
class RiceGrade {
  final String label;
  final String displayName;

  /// One line, shown wherever the grade is listed.
  final String summary;

  /// A short paragraph for the grade's Guide page.
  final String description;

  /// Visual characteristics generally associated with the class.
  final List<String> characteristics;

  const RiceGrade({
    required this.label,
    required this.displayName,
    required this.summary,
    required this.description,
    required this.characteristics,
  });
}

const premiumGrade = RiceGrade(
  label: 'Premium',
  displayName: 'Premium',
  summary: 'The highest-quality class of the three.',
  description:
      'Premium is the class this project uses for its highest-quality rice '
      'samples. In everyday use, "premium" describes a product of higher quality.',
  characteristics: [
    'Mostly whole grains, with few broken pieces',
    'Clean grains with an even color',
    'Little or no foreign material',
  ],
);

const wellMilledGrade = RiceGrade(
  label: 'Well-Milled',
  displayName: 'Well-Milled',
  summary: 'Milled rice, named after the milling process.',
  description:
      'Milling removes the husk and bran layers from rice. "Well-milled" '
      'generally describes rice with most of the bran removed, which usually '
      'makes the grains whiter. Well-Milled is one of the three classes the '
      'model was trained to recognize.',
  characteristics: [
    'Mostly white, milled grains',
    'Some broken pieces may be present',
  ],
);

const poorQualityRiceMixGrade = RiceGrade(
  label: 'Poor-Quality-Rice-Mix',
  displayName: 'Poor-Quality Rice Mix',
  summary: 'Lower-quality or mixed rice.',
  description:
      'Poor-Quality Rice Mix is the class this project uses for rice samples of '
      'lower visible quality, which can include grains of mixed quality. The '
      'model stores it as "Poor-Quality-Rice-Mix"; the app adds spaces only to '
      'make it easier to read.',
  characteristics: [
    'Broken pieces',
    'Discolored (yellowish or brownish) grains',
    'Chalky, opaque-white grains',
    'Foreign material, such as husk fragments',
  ],
);

/// In the same order as the model's classes (backend `CLASS_NAMES`).
const riceGrades = [premiumGrade, wellMilledGrade, poorQualityRiceMixGrade];

/// The grade with this backend label, or null for anything else, such as the
/// placeholder a failed prediction carries.
RiceGrade? gradeForLabel(String label) {
  for (final grade in riceGrades) {
    if (grade.label == label) {
      return grade;
    }
  }
  return null;
}

/// The text to draw for a backend label. Display only: a value that is not a
/// known grade is shown exactly as it arrived, and nothing stored or sent is
/// ever rewritten.
String gradeDisplayName(String label) => gradeForLabel(label)?.displayName ?? label;
