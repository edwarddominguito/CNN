import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/prediction_history_entry.dart';
import '../models/prediction_result.dart';
import '../services/history_service.dart';
import '../services/rice_api_service.dart';
import '../widgets/app_nav_scaffold.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final ImagePicker _picker = ImagePicker();
  final RiceApiService _apiService = RiceApiService();
  final HistoryService _historyService = HistoryService();

  XFile? selectedImage;
  Uint8List? selectedImageBytes;
  PredictionResult? result;
  bool isLoading = false;

  Future<void> pickImage(ImageSource source) async {
    final image = await _picker.pickImage(source: source, imageQuality: 85);
    if (image == null) return;

    final bytes = await image.readAsBytes();
    setState(() {
      selectedImage = image;
      selectedImageBytes = bytes;
      result = null;
    });
  }

  Future<void> predict() async {
    final image = selectedImage;
    if (image == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select or capture an image first.'),
        ),
      );
      return;
    }

    setState(() {
      isLoading = true;
      result = null;
    });

    final prediction = await _apiService.predictRiceGrade(image);

    if (!mounted) return;
    setState(() {
      result = prediction;
      isLoading = false;
    });

    await _historyService.addEntry(
      PredictionHistoryEntry.fromPrediction(
        result: prediction,
        createdAt: DateTime.now(),
        imagePath: image.path,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppNavScaffold(
      currentIndex: 1,
      title: 'Scan Rice',
      subtitle: 'Capture, preview, and classify a sample',
      body: AppPage(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 860;
              final preview = _ImagePreview(
                bytes: selectedImageBytes,
                name: selectedImage?.name,
              );
              final controls = _ScanControls(
                isLoading: isLoading,
                hasImage: selectedImage != null,
                onCamera: () => pickImage(ImageSource.camera),
                onGallery: () => pickImage(ImageSource.gallery),
                onPredict: predict,
              );

              if (!isWide) {
                return Column(
                  children: [preview, const SizedBox(height: 16), controls],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 7, child: preview),
                  const SizedBox(width: 20),
                  Expanded(flex: 5, child: controls),
                ],
              );
            },
          ),
          if (result != null) _PredictionCard(result: result!),
        ],
      ),
    );
  }
}

class _ImagePreview extends StatelessWidget {
  final Uint8List? bytes;
  final String? name;

  const _ImagePreview({required this.bytes, required this.name});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.image_search_outlined,
                    color: colorScheme.primary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Sample Preview',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        name ?? 'No sample loaded yet',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF68736D),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (bytes != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF6EF),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.check_circle,
                          size: 16,
                          color: Color(0xFF256D4F),
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Ready',
                          style: TextStyle(
                            color: Color(0xFF256D4F),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          AspectRatio(
            aspectRatio: 16 / 9.2,
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Color(0xFFF2F6F2),
                border: Border(top: BorderSide(color: Color(0xFFE0E5DF))),
              ),
              child: bytes == null
                  ? const _PreviewEmptyState()
                  : Image.memory(
                      bytes!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanControls extends StatelessWidget {
  final bool isLoading;
  final bool hasImage;
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onPredict;

  const _ScanControls({
    required this.isLoading,
    required this.hasImage,
    required this.onCamera,
    required this.onGallery,
    required this.onPredict,
  });

  @override
  Widget build(BuildContext context) {
    final canPredict = hasImage && !isLoading;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF6EF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.tune_outlined,
                  color: Color(0xFF256D4F),
                  size: 21,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Input Source',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Add a clear, well-lit rice sample.',
                      style: TextStyle(color: Color(0xFF68736D), fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 430;
              final buttons = [
                _SourceButton(
                  icon: Icons.camera_alt_outlined,
                  title: 'Camera',
                  subtitle: 'Capture now',
                  onPressed: isLoading ? null : onCamera,
                ),
                _SourceButton(
                  icon: Icons.photo_library_outlined,
                  title: 'Gallery',
                  subtitle: 'Pick existing',
                  onPressed: isLoading ? null : onGallery,
                ),
              ];

              if (compact) {
                return Column(
                  children: [
                    buttons[0],
                    const SizedBox(height: 12),
                    buttons[1],
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(child: buttons[0]),
                  const SizedBox(width: 12),
                  Expanded(child: buttons[1]),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: canPredict ? onPredict : null,
            icon: isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.analytics_outlined),
            label: Text(isLoading ? 'Analyzing...' : 'Predict Rice Grade'),
          ),
          const SizedBox(height: 16),
          _ScanStatus(hasImage: hasImage),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          const _CaptureTips(),
        ],
      ),
    );
  }
}

class _PreviewEmptyState extends StatelessWidget {
  const _PreviewEmptyState();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFD5DDD6), width: 1.2),
              ),
            ),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFFE0E5DF)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x10000000),
                        blurRadius: 18,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 34,
                    color: Color(0xFF256D4F),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Add a rice sample',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF1E2722),
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Keep grains in focus and fill most of the frame for a cleaner prediction.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF68736D), height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SourceButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onPressed;

  const _SourceButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;

    return Material(
      color: enabled ? Colors.white : const Color(0xFFF4F6F4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: enabled ? const Color(0xFFB8C7BE) : const Color(0xFFE0E5DF),
        ),
      ),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(
                icon,
                color: enabled
                    ? Theme.of(context).colorScheme.primary
                    : const Color(0xFF8B958F),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: enabled
                            ? const Color(0xFF1E2722)
                            : const Color(0xFF8B958F),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: enabled
                            ? const Color(0xFF68736D)
                            : const Color(0xFF8B958F),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanStatus extends StatelessWidget {
  final bool hasImage;

  const _ScanStatus({required this.hasImage});

  @override
  Widget build(BuildContext context) {
    final color = hasImage
        ? Theme.of(context).colorScheme.primary
        : const Color(0xFF68736D);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: hasImage ? const Color(0xFFEAF6EF) : const Color(0xFFF4F6F4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: hasImage ? const Color(0xFFCDE8D9) : const Color(0xFFE0E5DF),
        ),
      ),
      child: Row(
        children: [
          Icon(
            hasImage ? Icons.check_circle : Icons.info_outline,
            size: 20,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              hasImage
                  ? 'Image ready. Run prediction when you are set.'
                  : 'Choose or capture an image to enable prediction.',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureTips extends StatelessWidget {
  const _CaptureTips();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Capture Tips', style: TextStyle(fontWeight: FontWeight.w900)),
        SizedBox(height: 12),
        _TipRow(
          icon: Icons.center_focus_strong_outlined,
          text: 'Fill the frame with rice grains.',
        ),
        SizedBox(height: 10),
        _TipRow(
          icon: Icons.wb_sunny_outlined,
          text: 'Use even light and avoid glare.',
        ),
        SizedBox(height: 10),
        _TipRow(
          icon: Icons.layers_outlined,
          text: 'Place the sample on a flat surface.',
        ),
      ],
    );
  }
}

class _TipRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _TipRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF256D4F)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Color(0xFF68736D), height: 1.3),
          ),
        ),
      ],
    );
  }
}

class _PredictionCard extends StatelessWidget {
  final PredictionResult result;

  const _PredictionCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final error = result.error;

    return AppCard(
      color: error == null ? Colors.white : const Color(0xFFFFF5F4),
      child: error != null
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, color: Color(0xFFB3261E)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    error,
                    style: const TextStyle(
                      color: Color(0xFFB3261E),
                      fontWeight: FontWeight.bold,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            )
          : _PredictionSuccess(result: result),
    );
  }
}

class _PredictionSuccess extends StatelessWidget {
  final PredictionResult result;

  const _PredictionSuccess({required this.result});

  @override
  Widget build(BuildContext context) {
    final confidence = result.confidence.clamp(0, 100) / 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Prediction Result',
          style: TextStyle(
            color: Color(0xFF68736D),
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          result.predictedGrade,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: confidence.toDouble(),
            minHeight: 10,
            backgroundColor: const Color(0xFFE6EBE7),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${result.confidence.toStringAsFixed(2)}% confidence',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        if (result.processingTimeMs != null) ...[
          const SizedBox(height: 4),
          Text(
            'Processing time: ${result.processingTimeMs!.toStringAsFixed(2)} ms',
            style: const TextStyle(color: Color(0xFF68736D)),
          ),
        ],
        if (result.note != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF8E8),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFF0DFAE)),
            ),
            child: Text(
              result.note!,
              style: const TextStyle(color: Color(0xFF725600), height: 1.4),
            ),
          ),
        ],
      ],
    );
  }
}
