import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_colors.dart';
import '../models/prediction_history_entry.dart';
import '../models/prediction_result.dart';
import '../services/image_validation.dart';
import '../services/rice_api_service.dart';
import '../widgets/app_cards.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/image_preview.dart';
import '../widgets/prediction_result_card.dart';
import '../widgets/scan_controls.dart';

/// The main screen of the app.
///
/// Take or choose a photo -> preview it -> press Classify Rice -> the image is
/// validated here, then sent to FastAPI -> the grade and the model's own
/// confidence come back.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final ImagePicker _picker = ImagePicker();
  final RiceApiService _api = RiceApiService();

  XFile? image; // the photo the user picked
  Uint8List? imageBytes; // its contents, used for the preview and the checks
  PredictionResult? prediction; // what the CNN answered
  bool isLoading = false; // true while validating or waiting for FastAPI
  bool _isPicking = false;
  String loadingMessage = ''; // which of those two steps is running
  String? errorMessage; // why the last attempt stopped

  /// Used by both the Camera and the Gallery button, only [source] differs.
  Future<void> pickImage(ImageSource source) async {
    if (_isPicking || isLoading) return;
    _isPicking = true;
    XFile? picked;
    Uint8List? bytes;
    String? problem;

    try {
      picked = await _picker.pickImage(source: source, imageQuality: 85);
      if (picked == null) {
        return; // The user closed the camera or the picker.
      }
      if (await picked.length() > maxImageBytes) {
        problem = 'This image is too large. Please use an image under 15 MB.';
      } else {
        bytes = await picked.readAsBytes();
        problem = await validateImage(picked.name, bytes);
      }
    } on Exception catch (_) {
      // A denied camera or photo permission, or a file the phone cannot read.
      problem = 'Could not use that image. Check the camera and photo '
          'permissions for this app, then try another photo.';
    } finally {
      _isPicking = false;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      image = problem == null ? picked : null;
      imageBytes = problem == null ? bytes : null;
      prediction = null;
      errorMessage = problem;
    });
  }

  /// Validates the picked image, then asks the backend to classify it.
  Future<void> classifyRice() async {
    final picked = image;
    final bytes = imageBytes;
    if (picked == null || bytes == null || isLoading) {
      return; // Nothing to send, or a request is already running.
    }

    setState(() {
      isLoading = true;
      loadingMessage = 'Validating image...';
      prediction = null;
      errorMessage = null;
    });

    final problem = await validateImage(picked.name, bytes);
    if (!mounted) {
      return;
    }

    if (problem != null) {
      setState(() {
        isLoading = false;
        errorMessage = problem;
      });
      return; // An unusable image is never uploaded.
    }

    setState(() => loadingMessage = 'Analyzing rice image...');

    final result = await _api.predictRiceGrade(picked.name, bytes);
    if (!mounted) {
      return;
    }

    setState(() {
      isLoading = false;
      prediction = result.error == null ? result : null;
      errorMessage = result.error;
    });

    // Keep answers the backend could not record, including valid predictions
    // during a database outage. Already-recorded answers must not be duplicated.
    if (!result.savedByBackend) {
      await _api.saveUnsavedPrediction(
        PredictionHistoryEntry(
          predictedGrade: result.predictedGrade,
          confidence: result.confidence,
          createdAt: DateTime.now(),
          imagePath: picked.path,
          note: result.note,
          error: result.error,
        ),
      );
    }
  }

  void resetScan() {
    setState(() {
      image = null;
      imageBytes = null;
      prediction = null;
      isLoading = false;
      errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final preview = ImagePreview(imageBytes: imageBytes, imageName: image?.name);

    return AppNavScaffold(
      currentIndex: 1,
      title: 'Scan Rice',
      body: AppPage(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final actions = _buildActions();

              // Side by side in a wide window, stacked on a phone.
              if (constraints.maxWidth < 860) {
                return Column(children: [preview, const SizedBox(height: 16), actions]);
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 7, child: preview),
                  const SizedBox(width: 24),
                  Expanded(flex: 5, child: actions),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// Everything under (or beside) the preview. Exactly one of the three states
  /// is on screen at a time: working, finished, or waiting for the user.
  Widget _buildActions() {
    if (isLoading) {
      return _LoadingCard(message: loadingMessage);
    }

    final result = prediction;
    if (result != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PredictionResultCard(result: result),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: resetScan,
            icon: const Icon(Icons.refresh, size: 20),
            label: const Text('Scan Again'),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (errorMessage != null) ...[
          _ErrorCard(
            message: errorMessage!,
            onRetry: image == null ? null : classifyRice,
          ),
          const SizedBox(height: 12),
        ],
        ScanControls(
          hasImage: image != null,
          onCamera: () => pickImage(ImageSource.camera),
          onGallery: () => pickImage(ImageSource.gallery),
          onClassify: classifyRice,
        ),
      ],
    );
  }
}

/// Shown while a real step is running. The spinner has no value because
/// neither the validation nor the CNN reports measurable progress.
class _LoadingCard extends StatelessWidget {
  final String message;

  const _LoadingCard({required this.message});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 28),
      child: Column(
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 18),
          Text(message, style: textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Please wait while the image is being classified.',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// A failed validation or a failed request, in plain words.
class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const _ErrorCard({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      color: kErrorSurface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline, size: 20, color: kErrorText),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: kErrorText),
                ),
              ),
            ],
          ),
          if (onRetry != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onRetry, child: const Text('Try Again')),
            ),
        ],
      ),
    );
  }
}
