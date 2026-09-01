import 'package:flutter/material.dart';

// Every colour the app uses lives here.
// Change a value in this file and the whole app follows.
// The "k" prefix is the usual Flutter way of marking a constant.
//
// The palette is deliberately small: one accent, one neutral ramp, and one
// colour each for "went wrong" and "worth noticing". Anything that needs a
// new shade almost always wants one of these instead.

/// The single accent. Used for the active tab, primary buttons and icons.
const kPrimaryGreen = Color(0xFF256D4F);

/// Surfaces. The page sits a shade below the cards drawn on top of it.
const kPageBackground = Color(0xFFFAFBFA);
const kSurface = Colors.white;

/// A quiet fill for previews, code blocks and inactive states.
const kSubtleSurface = Color(0xFFF2F4F2);

/// Hairlines. Structure comes from these rather than from shadows.
const kBorderColor = Color(0xFFE6EAE6);

/// Text, from most to least prominent.
const kHeadingText = Color(0xFF161B18);
const kBodyText = Color(0xFF4E5A53);
const kMutedText = Color(0xFF8A938D);

/// Something failed.
const kErrorText = Color(0xFFB3261E);
const kErrorSurface = Color(0xFFFEF6F5);

/// Worth noticing, but not a failure.
const kAmber = Color(0xFF8A6500);
const kNoteSurface = Color(0xFFFDF9EF);
