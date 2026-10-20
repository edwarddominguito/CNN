import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'screens/about_screen.dart';
import 'screens/guide_screen.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'screens/scan_screen.dart';

void main() {
  runApp(const RiceGraderApp());
}

class RiceGraderApp extends StatelessWidget {
  const RiceGraderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rice Classifier',
      debugShowCheckedModeBanner: false,
      initialRoute: '/',
      // Every path here must also exist in appRoutes (widgets/app_scaffold.dart)
      // if it is meant to appear as a tab.
      routes: {
        '/': (context) => const HomeScreen(),
        '/scan': (context) => const ScanScreen(),
        '/history': (context) => const HistoryScreen(),
        '/guide': (context) => const GuideScreen(),
        '/about': (context) => const AboutScreen(),
      },
      theme: _buildTheme(),
    );
  }
}

/// The whole visual language of the app in one place.
///
/// Screens are expected to read their type styles from `Theme.of(context)`
/// rather than writing their own, so a change here reaches every screen.
ThemeData _buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: kPrimaryGreen,
      brightness: Brightness.light,
    ).copyWith(surface: kSurface, error: kErrorText),
  );

  // One rounded shape for every tappable thing.
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));

  return base.copyWith(
    scaffoldBackgroundColor: kPageBackground,
    dividerTheme: const DividerThemeData(
      color: kBorderColor,
      thickness: 1,
      space: 1,
    ),
    textTheme: base.textTheme
        .copyWith(
          // Screen title.
          titleLarge: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          // Card and section headings.
          titleMedium: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          // Numbers and other single-glance values.
          headlineSmall: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
          bodyMedium: const TextStyle(fontSize: 14, height: 1.45, color: kBodyText),
          bodySmall: const TextStyle(fontSize: 13, height: 1.4, color: kMutedText),
        )
        .apply(displayColor: kHeadingText, bodyColor: kBodyText),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: kSurface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      elevation: 0,
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected) ? kPrimaryGreen : kMutedText,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: states.contains(WidgetState.selected) ? kPrimaryGreen : kMutedText,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(0, 46), shape: shape),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 46),
        shape: shape,
        foregroundColor: kHeadingText,
        side: const BorderSide(color: kBorderColor),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: kPrimaryGreen),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: kBodyText),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: shape,
    ),
  );
}
